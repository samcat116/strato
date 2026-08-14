"use client";

export default function GlobalError({ reset }: { reset: () => void }) {
  return (
    <html lang="en">
      <body>
        <main style={{ minHeight: "100vh", display: "grid", placeItems: "center", padding: 24 }}>
          <div style={{ textAlign: "center" }}>
            <h1>Strato could not start</h1>
            <p>Reload the application. No operation was submitted.</p>
            <button type="button" onClick={reset}>Reload</button>
          </div>
        </main>
      </body>
    </html>
  );
}
