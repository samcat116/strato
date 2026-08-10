# Graphics Console

Every Strato VM has a serial console. That is enough for a cloud image that
boots to a login prompt and enough for most debugging, and it is useless the
moment the guest wants to draw something: an OS installer booted from an ISO,
Windows Setup, a desktop environment, or a machine that panicked before it
reached a getty.

The **graphics console** gives such a VM a virtual display and streams its
framebuffer to the browser, with keyboard and mouse. It is opt-in, and it is
chosen when the VM is created.

## Creating a VM with a display

In the create-VM dialog, turn on **Display**. Over the API, set
`graphicsConsole` on the create request:

```bash
curl -X POST https://strato.example.com/api/vms \
  -H "Authorization: Bearer $STRATO_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
        "name": "ubuntu-desktop",
        "imageId": "…",
        "projectId": "…",
        "networkId": "…",
        "cpu": 2,
        "memory": 4294967296,
        "disk": 53687091200,
        "graphicsConsole": true
      }'
```

Then start the VM and open its **Display** tab.

::: warning This cannot be changed later
The display device lives in the hypervisor process's argument vector, and a
stopped VM restarts from the arguments it was created with. So a VM created
headless cannot gain a display, and one created with a display cannot drop it —
in either case, create a new VM. The same is true of Secure Boot and the vTPM.
:::

## What the VM gets

- A **standard VGA** adapter on x86 (`virtio-gpu` on arm64). Deliberately not a
  virtio display on x86: the whole value of this console is output from before
  any guest driver has loaded — firmware, the boot loader, an installer, a blue
  screen — and virtio needs a driver for anything past its compatibility mode.
- A **USB tablet**, which reports absolute pointer positions. Without one the
  guest's cursor drifts away from yours and a graphical installer becomes
  impossible to click.
- A **VNC server on a Unix socket** inside the VM's own directory on the
  hypervisor node. Nothing listens on the network.

The serial console keeps working exactly as before, on the same VM, at the same
time. Opening one does not disconnect the other, and several people can watch
the same display at once.

## Sending Ctrl+Alt+Del

Browsers intercept Ctrl+Alt+Del before any web page sees it, so the Display tab
has a button that sends it to the guest directly.

## Requirements

- **QEMU.** Firecracker emulates no display device at all, so the API rejects
  `graphicsConsole` for a Firecracker VM rather than creating one whose Display
  tab could never work.
- **An agent running wire protocol v23 or newer.** Older agents ignore the
  request and would boot the guest headless while the API claimed otherwise, so
  the scheduler refuses to place such a VM instead. If no node in your fleet
  qualifies, the create fails with a message saying to upgrade the agents.
- **A control-plane replica holding the VM's agent socket.** Console traffic
  rides the agent's WebSocket, which lives on exactly one replica. Opening the
  display on another replica returns 503; retrying through the service resolves
  it. This is the same limitation the serial console has.

## Security model

There is **no VNC password**, and this is deliberate rather than an omission.
The VNC server binds a Unix socket in the VM's directory — never a TCP port —
so reaching it at all requires access to the hypervisor node's filesystem. From
the outside, the only path in is the control plane, which requires an
authenticated session (or an API key whose restriction includes `vm:viewConsole`) and the
`vm:viewConsole` permission on that specific VM, checked before the VM is even
looked up. A console session is minted single-use, expires in 60 seconds if
unused, and is bound to the VM and the user it was minted for.

This is the same trust model as the console and serial sockets that sit beside
it in the VM's directory: the socket's file mode and Strato's own authorization
are the boundary, not a shared secret.

## Limitations

- **No clipboard sharing.** Copy and paste between host and guest needs a guest
  agent channel that is not wired up yet.
- **No audio, and no GPU acceleration.** Neither SPICE nor virtio-gpu 3D /
  device passthrough is in scope; the console is for reaching a machine, not
  for using it as a workstation.
- **A busy screen costs bandwidth.** The framebuffer is relayed through the
  agent's WebSocket. RFB only sends updates the client asks for, so an idle
  desktop is nearly free, but a video-playing guest is not a good fit.
