use std::collections::HashMap;
use std::fmt::Write;

pub struct Request {
    pub method: String,
    pub path: String,
    pub query: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Request {
    pub fn new(method: &str, target: &str) -> Self {
        let (path, query) = target.split_once('?').unwrap_or((target, ""));
        Request {
            method: method.to_string(),
            path: path.to_string(),
            query: query.to_string(),
            headers: Vec::new(),
            body: Vec::new(),
        }
    }

    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }

    pub fn param(&self, name: &str) -> Option<String> {
        form_urlencoded::parse(self.query.as_bytes())
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.into_owned())
    }

    pub fn form(&self) -> HashMap<String, String> {
        form_urlencoded::parse(&self.body).into_owned().collect()
    }

    pub fn cookie(&self, name: &str) -> Option<&str> {
        self.header("cookie")?
            .split(';')
            .filter_map(|pair| pair.trim().split_once('='))
            .find(|(key, _)| *key == name)
            .map(|(_, value)| value)
    }
}

pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Response {
    pub fn new(status: u16) -> Self {
        Response {
            status,
            headers: vec![("Cache-Control".to_string(), "no-store".to_string())],
            body: Vec::new(),
        }
    }

    pub fn text(status: u16, body: &str) -> Self {
        Response::new(status)
            .with("Content-Type", "text/plain; charset=utf-8")
            .body(body.as_bytes())
    }

    pub fn html(status: u16, title: &str, body: &str) -> Self {
        let page = format!(
            "<!doctype html>\n<html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\">\
             <title>{}</title></head>\n<body>\n{body}\n</body></html>\n",
            escape(title)
        );
        Response::new(status)
            .with("Content-Type", "text/html; charset=utf-8")
            .body(page.as_bytes())
    }

    pub fn json(status: u16, value: &serde_json::Value) -> Self {
        Response::new(status)
            .with("Content-Type", "application/json")
            .body(value.to_string().as_bytes())
    }

    // Policy: a redirect is 303, which has the browser get where it's sent whatever it asked, and which, as any
    // redirect, leaves the page it answers out of the browser's history.
    pub fn redirect(location: &str) -> Self {
        Response::new(303).with("Location", location)
    }

    pub fn with(mut self, name: &str, value: &str) -> Self {
        self.headers.push((name.to_string(), value.to_string()));
        self
    }

    pub fn body(mut self, body: &[u8]) -> Self {
        self.body = body.to_vec();
        self
    }

    #[cfg(test)]
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }
}

pub fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

pub fn query(pairs: &[(&str, &str)]) -> String {
    form_urlencoded::Serializer::new(String::new())
        .extend_pairs(pairs)
        .finish()
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().fold(String::new(), |mut out, byte| {
        let _ = write!(out, "{byte:02x}");
        out
    })
}
