//! Host-initiated AF_VSOCK listener for the VM guest agent.

use std::io::{BufReader, Write};
use std::mem;
use std::os::fd::{FromRawFd, OwnedFd};
use std::os::unix::io::AsRawFd;
use std::sync::Arc;

use strato_sandbox_init::protocol::{
    decode_request, encode_line, read_request_line, Request, Response, WorkloadState,
    CONTROL_PROTOCOL_VERSION, DEFAULT_VSOCK_PORT,
};

use super::exec::{self, ExecRequest};
use super::GuestIdentity;

/// Bind the well-known guest port and serve connections for the process's
/// lifetime. A service restart calls this again and re-establishes the socket.
pub fn serve(identity: Arc<GuestIdentity>) -> Result<(), String> {
    let listener = bind_listener(DEFAULT_VSOCK_PORT)?;
    eprintln!("[strato-guest-agent] listening on vsock port {DEFAULT_VSOCK_PORT}");

    loop {
        let mut peer: libc::sockaddr_vm = unsafe { mem::zeroed() };
        let mut peer_len = mem::size_of::<libc::sockaddr_vm>() as libc::socklen_t;
        // SAFETY: accept(2) initializes `peer` and returns a fresh owned fd.
        let raw = unsafe {
            libc::accept(
                listener.as_raw_fd(),
                &mut peer as *mut libc::sockaddr_vm as *mut libc::sockaddr,
                &mut peer_len,
            )
        };
        if raw < 0 {
            let err = std::io::Error::last_os_error();
            if err.kind() != std::io::ErrorKind::Interrupted {
                eprintln!("[strato-guest-agent] vsock accept failed: {err}");
            }
            continue;
        }
        let connection = unsafe { OwnedFd::from_raw_fd(raw) };

        // The control plane reaches the guest through the hypervisor's host
        // endpoint (CID 2). Refuse guest-local vsock clients: the daemon is a
        // host control surface, not a tenant-visible local privilege API.
        if !is_host_peer(&peer, peer_len) {
            eprintln!(
                "[strato-guest-agent] refused non-host vsock peer cid {}",
                peer.svm_cid
            );
            continue;
        }

        let connection_identity = Arc::clone(&identity);
        let spawned = std::thread::Builder::new()
            .name("guest-vsock-conn".to_string())
            .spawn(move || {
                if let Err(e) = handle_connection(connection, &connection_identity) {
                    eprintln!("[strato-guest-agent] vsock connection error: {e}");
                }
            });
        if let Err(e) = spawned {
            eprintln!("[strato-guest-agent] spawn connection thread: {e}");
        }
    }
}

fn is_host_peer(peer: &libc::sockaddr_vm, peer_len: libc::socklen_t) -> bool {
    peer_len as usize == mem::size_of::<libc::sockaddr_vm>()
        && peer.svm_family == libc::AF_VSOCK as libc::sa_family_t
        && peer.svm_cid == libc::VMADDR_CID_HOST
}

fn bind_listener(port: u32) -> Result<OwnedFd, String> {
    // SAFETY: standard socket(2)/bind(2)/listen(2) on AF_VSOCK only. This
    // executable never creates an AF_INET or AF_INET6 socket.
    unsafe {
        let raw = libc::socket(libc::AF_VSOCK, libc::SOCK_STREAM, 0);
        if raw < 0 {
            return Err(format!(
                "socket(AF_VSOCK): {}",
                std::io::Error::last_os_error()
            ));
        }
        let listener = OwnedFd::from_raw_fd(raw);
        let mut address: libc::sockaddr_vm = mem::zeroed();
        address.svm_family = libc::AF_VSOCK as libc::sa_family_t;
        address.svm_cid = libc::VMADDR_CID_ANY;
        address.svm_port = port;
        if libc::bind(
            listener.as_raw_fd(),
            &address as *const libc::sockaddr_vm as *const libc::sockaddr,
            mem::size_of::<libc::sockaddr_vm>() as libc::socklen_t,
        ) < 0
        {
            return Err(format!(
                "bind(vsock:{port}): {}",
                std::io::Error::last_os_error()
            ));
        }
        if libc::listen(listener.as_raw_fd(), 16) < 0 {
            return Err(format!(
                "listen(vsock:{port}): {}",
                std::io::Error::last_os_error()
            ));
        }
        Ok(listener)
    }
}

fn handle_connection(connection: OwnedFd, identity: &GuestIdentity) -> std::io::Result<()> {
    let writer_fd = connection.try_clone()?;
    let mut writer = std::fs::File::from(writer_fd);
    let mut reader = BufReader::new(std::fs::File::from(connection));

    let mut first = String::new();
    loop {
        if read_request_line(&mut reader, &mut first)? == 0 {
            return Ok(());
        }
        if !first.trim().is_empty() {
            break;
        }
    }

    match decode_request(&first) {
        Ok(request @ (Request::Ping | Request::GetStatus)) => {
            serve_control(request, reader, writer, identity)
        }
        Ok(Request::Exec {
            argv,
            env,
            cwd,
            tty,
            rows,
            cols,
        }) => {
            exec::run_exec_session(
                reader,
                writer,
                ExecRequest {
                    argv,
                    env,
                    cwd,
                    tty,
                    rows,
                    cols,
                },
                identity.nonce.clone(),
            );
            Ok(())
        }
        Ok(_) => write_response(
            &mut writer,
            &Response::Error {
                nonce: identity.nonce.clone(),
                message: "this VM guest agent supports only ping/get_status/exec".to_string(),
            },
        ),
        Err(e) => write_response(
            &mut writer,
            &Response::Error {
                nonce: identity.nonce.clone(),
                message: format!("undecodable request: {e}"),
            },
        ),
    }
}

fn serve_control(
    first: Request,
    mut reader: BufReader<std::fs::File>,
    mut writer: std::fs::File,
    identity: &GuestIdentity,
) -> std::io::Result<()> {
    write_response(&mut writer, &control_response(first, identity))?;

    let mut line = String::new();
    loop {
        if read_request_line(&mut reader, &mut line)? == 0 {
            return Ok(());
        }
        if line.trim().is_empty() {
            continue;
        }
        let response = match decode_request(&line) {
            Ok(request @ (Request::Ping | Request::GetStatus)) => {
                control_response(request, identity)
            }
            Ok(_) => Response::Error {
                nonce: identity.nonce.clone(),
                message: "only ping/get_status are valid on a VM control connection".to_string(),
            },
            Err(e) => Response::Error {
                nonce: identity.nonce.clone(),
                message: format!("undecodable request: {e}"),
            },
        };
        write_response(&mut writer, &response)?;
    }
}

fn control_response(request: Request, identity: &GuestIdentity) -> Response {
    match request {
        Request::GetStatus => Response::Status {
            sandbox_id: identity.guest_id.clone(),
            nonce: identity.nonce.clone(),
            state: WorkloadState::Running,
            exit_code: None,
        },
        _ => Response::Pong {
            sandbox_id: identity.guest_id.clone(),
            nonce: identity.nonce.clone(),
            control_protocol_version: CONTROL_PROTOCOL_VERSION,
        },
    }
}

fn write_response(writer: &mut std::fs::File, response: &Response) -> std::io::Result<()> {
    writer.write_all(encode_line(response).as_bytes())?;
    writer.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::os::fd::OwnedFd;
    use std::os::unix::net::UnixStream;

    use strato_sandbox_init::protocol::{decode_base64, Request};

    fn identity() -> GuestIdentity {
        GuestIdentity {
            guest_id: "machine-1".into(),
            nonce: "boot-1".into(),
        }
    }

    fn connection() -> (UnixStream, std::thread::JoinHandle<()>) {
        let (client, server) = UnixStream::pair().expect("socket pair");
        let handle = std::thread::spawn(move || {
            handle_connection(OwnedFd::from(server), &identity()).expect("serve connection");
        });
        (client, handle)
    }

    #[test]
    fn only_the_hypervisor_host_cid_is_accepted() {
        let mut peer: libc::sockaddr_vm = unsafe { mem::zeroed() };
        peer.svm_family = libc::AF_VSOCK as libc::sa_family_t;
        peer.svm_cid = libc::VMADDR_CID_HOST;
        let full_len = mem::size_of::<libc::sockaddr_vm>() as libc::socklen_t;
        assert!(is_host_peer(&peer, full_len));

        peer.svm_cid = libc::VMADDR_CID_LOCAL;
        assert!(!is_host_peer(&peer, full_len));
        peer.svm_cid = libc::VMADDR_CID_HOST;
        assert!(!is_host_peer(&peer, full_len - 1));
    }

    fn read_response(reader: &mut impl BufRead) -> Response {
        let mut line = String::new();
        reader.read_line(&mut line).expect("read response");
        assert!(!line.is_empty(), "connection closed before response");
        serde_json::from_str(line.trim()).expect("decode response")
    }

    #[test]
    fn one_control_connection_serves_ping_and_status() {
        let (mut client, handle) = connection();
        let mut reader = BufReader::new(client.try_clone().expect("clone client"));
        client
            .write_all(b"{\"type\":\"ping\"}\n{\"type\":\"get_status\"}\n")
            .expect("write requests");

        assert_eq!(
            read_response(&mut reader),
            Response::Pong {
                sandbox_id: "machine-1".into(),
                nonce: "boot-1".into(),
                control_protocol_version: CONTROL_PROTOCOL_VERSION,
            }
        );
        assert_eq!(
            read_response(&mut reader),
            Response::Status {
                sandbox_id: "machine-1".into(),
                nonce: "boot-1".into(),
                state: WorkloadState::Running,
                exit_code: None,
            }
        );
        drop(client);
        drop(reader);
        handle.join().expect("connection thread");
    }

    #[test]
    fn non_tty_exec_relays_stdin_both_outputs_and_exit_with_nonce() {
        let (mut client, handle) = connection();
        let mut reader = BufReader::new(client.try_clone().expect("clone client"));
        let request = Request::Exec {
            argv: vec![
                "/bin/sh".into(),
                "-c".into(),
                "read line; printf 'out:%s' \"$line\"; printf err >&2; exit 7".into(),
            ],
            env: None,
            cwd: None,
            tty: Some(false),
            rows: None,
            cols: None,
        };
        client
            .write_all(encode_line(&request).as_bytes())
            .expect("write exec");
        assert_eq!(
            read_response(&mut reader),
            Response::ExecStarted {
                nonce: "boot-1".into(),
            }
        );
        client
            .write_all(b"{\"type\":\"stdin\",\"data\":\"aGVsbG8K\"}\n{\"type\":\"stdin_eof\"}\n")
            .expect("write stdin");

        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        loop {
            match read_response(&mut reader) {
                Response::Output {
                    nonce,
                    stream,
                    data,
                } => {
                    assert_eq!(nonce, "boot-1");
                    let bytes = decode_base64(&data).expect("base64 output");
                    match stream.as_str() {
                        "stdout" => stdout.extend(bytes),
                        "stderr" => stderr.extend(bytes),
                        other => panic!("unexpected stream {other}"),
                    }
                }
                Response::ExecExit { nonce, exit_code } => {
                    assert_eq!(nonce, "boot-1");
                    assert_eq!(exit_code, 7);
                    break;
                }
                other => panic!("unexpected response: {other:?}"),
            }
        }
        assert_eq!(stdout, b"out:hello");
        assert_eq!(stderr, b"err");
        drop(client);
        handle.join().expect("connection thread");
    }

    #[test]
    fn tty_exec_applies_resize_and_relays_input() {
        let (mut client, handle) = connection();
        let mut reader = BufReader::new(client.try_clone().expect("clone client"));
        let request = Request::Exec {
            argv: vec![
                "/bin/sh".into(),
                "-c".into(),
                "read line; stty size; printf 'input:%s' \"$line\"".into(),
            ],
            env: None,
            cwd: None,
            tty: Some(true),
            rows: Some(24),
            cols: Some(80),
        };
        client
            .write_all(encode_line(&request).as_bytes())
            .expect("write exec");
        assert!(matches!(
            read_response(&mut reader),
            Response::ExecStarted { nonce } if nonce == "boot-1"
        ));
        client
            .write_all(
                b"{\"type\":\"resize\",\"rows\":41,\"cols\":132}\n{\"type\":\"stdin\",\"data\":\"aGkK\"}\n",
            )
            .expect("resize and stdin");

        let mut output = Vec::new();
        loop {
            match read_response(&mut reader) {
                Response::Output {
                    nonce,
                    stream,
                    data,
                } => {
                    assert_eq!(nonce, "boot-1");
                    assert_eq!(stream, "stdout");
                    output.extend(decode_base64(&data).expect("base64 output"));
                }
                Response::ExecExit { nonce, exit_code } => {
                    assert_eq!(nonce, "boot-1");
                    assert_eq!(exit_code, 0);
                    break;
                }
                other => panic!("unexpected response: {other:?}"),
            }
        }
        let output = String::from_utf8_lossy(&output);
        assert!(output.contains("41 132"), "resized tty output: {output:?}");
        assert!(output.contains("input:hi"), "tty stdin output: {output:?}");
        drop(client);
        handle.join().expect("connection thread");
    }
}
