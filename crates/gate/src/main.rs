mod devices;
mod gate;
mod http;
mod oidc;
#[cfg(test)]
mod tests;

use std::io::Read;
use std::process::ExitCode;
use std::sync::Arc;

// Fact: a form of the gate's is a few hundred bytes, and a logout token a few kilobytes.
const MAX_BODY: u64 = 64 * 1024;
const WORKERS: usize = 8;

fn start() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let (Some(path), None) = (args.next(), args.next()) else {
        return Err("usage: gate <config.json>".to_string());
    };
    let config: gate::Config =
        serde_json::from_slice(&std::fs::read(&path).map_err(|error| format!("{path}: {error}"))?)
            .map_err(|error| format!("{path}: {error}"))?;
    let secret = std::fs::read_to_string(&config.secret_file)
        .map_err(|error| format!("{}: {error}", config.secret_file.display()))?
        .trim()
        .to_string();
    let issuer = oidc::Remote::discover(&config.issuer)?;
    let server = tiny_http::Server::http(&config.listen).map_err(|error| format!("{}: {error}", config.listen))?;
    let gate = Arc::new(gate::Gate::new(config, secret, Box::new(issuer))?);
    let server = Arc::new(server);
    let workers: Vec<_> = (0..WORKERS)
        .map(|_| {
            let (server, gate) = (server.clone(), gate.clone());
            std::thread::spawn(move || {
                while let Ok(request) = server.recv() {
                    serve(&gate, request);
                }
            })
        })
        .collect();
    for worker in workers {
        let _ = worker.join();
    }
    Err("the server stopped".to_string())
}

fn serve(gate: &gate::Gate, mut incoming: tiny_http::Request) {
    let mut request = http::Request::new(incoming.method().as_str(), incoming.url());
    request.headers = incoming
        .headers()
        .iter()
        .map(|header| (header.field.as_str().to_string(), header.value.as_str().to_string()))
        .collect();
    let response = if incoming
        .as_reader()
        .take(MAX_BODY + 1)
        .read_to_end(&mut request.body)
        .is_err()
    {
        http::Response::text(400, "The request's body couldn't be read.")
    } else if request.body.len() as u64 > MAX_BODY {
        http::Response::text(413, "Too large.")
    } else {
        gate.handle(&request)
    };
    let mut reply = tiny_http::Response::from_data(response.body).with_status_code(response.status);
    for (name, value) in &response.headers {
        if let Ok(header) = tiny_http::Header::from_bytes(name.as_bytes(), value.as_bytes()) {
            reply.add_header(header);
        }
    }
    let _ = incoming.respond(reply);
}

fn main() -> ExitCode {
    match start() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("gate: {error}");
            ExitCode::FAILURE
        }
    }
}
