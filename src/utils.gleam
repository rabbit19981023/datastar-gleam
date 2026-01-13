import ewe.{type Request, type Response, type ResponseBody, TextData}
import gleam/http
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import logging
import marceau

pub fn serve_static(req: Request, path: String) -> Response {
  let mime_type =
    req.path
    |> string.split(".")
    |> list.last
    |> result.unwrap("")
    |> marceau.extension_to_mime_type

  let content_type = case mime_type {
    "application/json" | "text/" <> _ -> mime_type <> "; charset=utf-8"
    _ -> mime_type
  }

  case ewe.file("priv/static/" <> path, offset: None, limit: None) {
    Ok(file) -> send_file(file, content_type)
    Error(_) -> send_not_found()
  }
}

pub fn send_not_found() -> Response {
  response.new(404)
  |> response.set_body(TextData("Not found"))
}

pub fn send_html(html: String) -> Response {
  response.new(200)
  |> response.set_header("Content-Type", "text/html; charset=utf-8")
  |> response.set_body(TextData(html))
}

pub fn send_file(file: ResponseBody, content_type: String) -> Response {
  response.new(200)
  |> response.set_header("Content-Type", content_type)
  |> response.set_body(file)
}

pub fn log_request(req: Request, handler: fn() -> Response) -> Response {
  let response = handler()

  [
    int.to_string(response.status),
    " ",
    string.uppercase(http.method_to_string(req.method)),
    " ",
    req.path,
  ]
  |> string.concat
  |> logging.log(logging.Info, _)

  response
}
