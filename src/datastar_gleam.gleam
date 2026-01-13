import ewe.{type Request, type Response, type SSEEvent}
import gleam/erlang/process.{type Subject}
import gleam/http.{Get}
import gleam/http/request
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor} as supervisor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/string
import logging
import utils.{log_request, send_file, send_html, send_not_found}

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Info)

  let pubsub = process.new_name("pubsub")

  let assert Ok(_) =
    supervisor.new(supervisor.OneForAll)
    |> supervisor.add(web_server(pubsub))
    |> supervisor.add(pubsub_worker(pubsub))
    |> supervisor.start()

  process.sleep_forever()
}

fn web_server(pubsub: process.Name(PubsubMsg)) -> ChildSpecification(Supervisor) {
  request_handler(_, process.named_subject(pubsub))
  |> ewe.new()
  |> ewe.bind_all()
  |> ewe.listening(port: 8000)
  |> ewe.supervised()
}

fn request_handler(req: Request, pubsub: Subject(PubsubMsg)) -> Response {
  use <- log_request(req)

  case req.method, request.path_segments(req) {
    Get, [] -> serve_index()
    Get, ["hal-html"] -> get_hal_html()
    Get, ["hal-sse"] -> get_hal_sse(req, pubsub)
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

type PubsubMsg {
  Subscribe(client: Subject(SSEEvent))
  Send(client: Subject(SSEEvent), event: SSEEvent)
  Unsubscribe(client: Subject(SSEEvent))
}

fn pubsub_worker(
  pubsub: process.Name(PubsubMsg),
) -> ChildSpecification(Subject(PubsubMsg)) {
  let init_clients = []
  use <- supervision.worker

  actor.new(init_clients)
  |> actor.named(pubsub)
  |> actor.on_message(pubsub_handler)
  |> actor.start()
}

fn pubsub_handler(
  clients: List(Subject(SSEEvent)),
  msg: PubsubMsg,
) -> actor.Next(List(Subject(SSEEvent)), PubsubMsg) {
  case msg {
    Subscribe(client) -> {
      let assert Ok(pid) = process.subject_owner(client)

      logging.log(
        logging.Info,
        "Client " <> string.inspect(pid) <> " connected",
      )

      actor.continue([client, ..clients])
    }

    Send(client, event) -> {
      let assert Ok(pid) = process.subject_owner(client)

      process.send(client, event)

      logging.log(
        logging.Info,
        "Sent event `"
          <> string.inspect(event)
          <> "` to client "
          <> string.inspect(pid),
      )

      actor.continue(clients)
    }

    Unsubscribe(client) -> {
      let assert Ok(pid) = process.subject_owner(client)

      logging.log(
        logging.Info,
        "Client " <> string.inspect(pid) <> " disconnected",
      )

      // remove unsubscribed client from list
      list.filter(clients, fn(subscribed) { subscribed != client })
      |> actor.continue()
    }
  }
}

fn get_hal_sse(req: Request, pubsub: Subject(PubsubMsg)) -> Response {
  ewe.sse(
    req,
    on_init: fn(client) {
      process.send(pubsub, Subscribe(client))

      logging.log(
        logging.Info,
        "SSE connection opened: " <> string.inspect(process.self()),
      )

      let patch =
        ewe.event(
          "elements <div id=\"hal-sse\">I’m sorry, Dave. I’m afraid I can’t do that. (text/event-stream)</div>",
        )
        |> ewe.event_name("datastar-patch-elements")

      process.send(pubsub, Send(client, patch))

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
    on_close: fn(_conn, client) {
      process.send(pubsub, Unsubscribe(client))

      logging.log(
        logging.Info,
        "SSE connection closed: " <> string.inspect(process.self()),
      )
    },
  )
}
