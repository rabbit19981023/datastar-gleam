import ewe.{type Request, type Response, type SSEEvent}
import gleam/erlang/process.{type Subject}
import gleam/http.{Get}
import gleam/http/request
import gleam/int
import gleam/option.{None}
import gleam/otp/static_supervisor.{type Supervisor} as supervisor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/string
import logging
import utils.{log_request, send_file, send_html, send_not_found}

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Info)

  let assert Ok(_) =
    supervisor.new(supervisor.OneForAll)
    |> supervisor.add(web_server())
    |> supervisor.start()

  process.sleep_forever()
}

fn web_server() -> ChildSpecification(Supervisor) {
  request_handler
  |> ewe.new()
  |> ewe.bind_all()
  |> ewe.listening(port: 8000)
  |> ewe.supervised()
}

fn request_handler(req: Request) -> Response {
  use <- log_request(req)

  case req.method, request.path_segments(req) {
    Get, [] -> serve_index()
    Get, ["hal-html"] -> get_hal_html()
    Get, ["hal-sse"] -> get_hal_sse(req)
    _, _ -> send_not_found()
  }
}

fn serve_index() -> Response {
  case ewe.file("src/index.html", offset: None, limit: None) {
    Ok(file) -> send_file(file, "text/html; charset=utf-8")
    Error(_) -> send_not_found()
  }
}

fn get_hal_html() -> Response {
  send_html(
    "<div id=\"hal-html\"> I’m sorry, Dave. I’m afraid I can’t do that. (text/html)</div>",
  )
}

fn get_hal_sse(req: Request) -> Response {
  ewe.sse(
    req,
    on_init: fn(client) {
      logging.log(
        logging.Info,
        "SSE connection opened: " <> string.inspect(process.self()),
      )

      // send events concurrently to avoid blocking SSE init connection
      process.spawn(fn() { send_event_loop(5, client) })

      client
    },
    handler: fn(conn, client, event) {
      logging.log(logging.Info, "SSE event received: " <> string.inspect(event))

      case ewe.send_event(conn, event) {
        Ok(Nil) -> ewe.sse_continue(client)

        Error(err) -> {
          logging.log(logging.Error, "SSE error: " <> string.inspect(err))
          ewe.sse_stop()
        }
      }
    },
    on_close: fn(_conn, _client) {
      logging.log(
        logging.Info,
        "SSE connection closed: " <> string.inspect(process.self()),
      )
    },
  )
}

fn send_event_loop(repeat: Int, client: Subject(SSEEvent)) {
  let patch =
    ewe.event(
      "elements "
      <> "<div id=\"hal-sse\">"
      <> "Times: "
      <> int.to_string(repeat)
      <> ". I’m sorry, Dave. I’m afraid I can’t do that. (text/event-stream)</div>",
    )
    |> ewe.event_name("datastar-patch-elements")

  process.send(client, patch)

  let delay = 800
  process.sleep(delay)
  case repeat {
    0 -> Nil
    _ -> send_event_loop(repeat - 1, client)
  }
}
