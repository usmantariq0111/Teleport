use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;

pub async fn start_host(mut rx: mpsc::Receiver<String>) {
    println!("📡 Host mode: Listening on 0.0.0.0:8080...");
    let listener = TcpListener::bind("0.0.0.0:8080").await.unwrap();

    // Accept the first connection
    if let Ok((mut socket, addr)) = listener.accept().await {
        println!("✅ Client connected from: {:?}", addr);

        // Stream file events to the client
        while let Some(msg) = rx.recv().await {
            let payload = format!("{}\n", msg);
            if let Err(e) = socket.write_all(payload.as_bytes()).await {
                eprintln!("❌ Failed to send data: {}", e);
                break;
            }
        }
    }
}

pub async fn start_client(ip: &str, _rx: mpsc::Receiver<String>) {
    let addr = format!("{}:8080", ip);
    println!("📡 Join mode: Connecting to {}...", addr);

    match TcpStream::connect(&addr).await {
        Ok(mut socket) => {
            println!("✅ Successfully connected to host!");
            
            let mut buf = vec![0; 1024];

            // In a real app, we'd handle both sending local changes and reading remote changes concurrently.
            // For the POC, the client will just listen and print remote changes from the host.
            loop {
                match socket.read(&mut buf).await {
                    Ok(0) => {
                        println!("❌ Host disconnected.");
                        break;
                    }
                    Ok(n) => {
                        let msg = String::from_utf8_lossy(&buf[..n]);
                        print!("🌐 Remote changed: {}", msg);
                    }
                    Err(e) => {
                        eprintln!("❌ Failed to read data: {}", e);
                        break;
                    }
                }
            }
        }
        Err(e) => {
            eprintln!("❌ Failed to connect: {}", e);
        }
    }
}
