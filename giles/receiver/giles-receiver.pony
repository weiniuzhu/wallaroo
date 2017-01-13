"""
Giles receiver
"""
use "collections"
use "files"
use "net"
use "options"
use "signals"
use "time"
use "sendence/messages"
use "sendence/bytes"
use "debug"

// tests
// documentation

actor Main
  new create(env: Env) =>
    var required_args_are_present = true
    var run_tests = env.args.size() == 1
    var use_metrics = false
    var no_write = false

    if run_tests then
      TestMain(env)
    else
      var p_arg: (Array[String] | None) = None
      var l_arg: (Array[String] | None) = None
      var n_arg: (String | None) = None
      var e_arg: (USize | None) = None

      try
        var options = Options(env.args)

        options
          .add("phone-home", "d", StringArgument)
          .add("name", "n", StringArgument)
          .add("listen", "l", StringArgument)
          .add("expect", "e", I64Argument)
          .add("metrics", "m", None)
          .add("no-write", "w", None)

        for option in options do
          match option
          | ("name", let arg: String) => n_arg = arg
          | ("phone-home", let arg: String) => p_arg = arg.split(":")
          | ("listen", let arg: String) => l_arg = arg.split(":")
          | ("expect", let arg: I64) => e_arg = arg.usize()
          | ("metrics", None) => use_metrics = true
          | ("no-write", None) => no_write = true
          | let err: ParseError =>
            err.report(env.err)
            required_args_are_present = false
          end
        end

        if l_arg is None then
          env.err.print("Must supply required '--listen' argument")
          required_args_are_present = false
        else
          if (l_arg as Array[String]).size() != 2 then
            env.err.print(
              "'--listen' argument should be in format: '127.0.0.1:8080")
            required_args_are_present = false
          end
        end

        if p_arg isnt None then
          if (p_arg as Array[String]).size() != 2 then
            env.err.print(
              "'--phone-home' argument should be in format: '127.0.0.1:8080")
            required_args_are_present = false
          end
        end

        if (p_arg isnt None) or (n_arg isnt None) then
          if (p_arg is None) or (n_arg is None) then
            env.err.print(
              "'--phone-home' must be used in conjunction with '--name'")
            required_args_are_present = false
          end
        end

        if (e_arg isnt None) then
          try
            let e' = (e_arg as USize)
            if e' < 1 then error end
          else
            env.err.print(
              "'--expect' must be an integer greater than 0")
            required_args_are_present = false
          end
        end

        if required_args_are_present then
          let listener_addr = l_arg as Array[String]

          let store = Store(env.root as AmbientAuth)
          let coordinator = CoordinatorFactory(env, store, n_arg, p_arg)

          SignalHandler(TermHandler(coordinator), Sig.term())
          SignalHandler(TermHandler(coordinator), Sig.int())

          let tcp_auth = TCPListenAuth(env.root as AmbientAuth)
          let from_buffy_listener = TCPListener(tcp_auth,
            FromBuffyListenerNotify(coordinator, store, env.err, e_arg,
              use_metrics, no_write),
            listener_addr(0),
            listener_addr(1))

        end
      else
        env.err.print(
          """
          --phone-home/-p <address> [Sets the address for phone home]
          --name/-n <name> [Name of giles-receiver node]
          --listen/-l <address> [Address giles-receiver node is listening on]
          --expect/-e <number> [Number of messages to process before terminating]
          --metrics/-m [Add metrics reporting]
          """)
      end
    end

class FromBuffyListenerNotify is TCPListenNotify
  let _coordinator: Coordinator
  let _store: Store
  let _stderr: StdStream
  let _expected: (USize | None)
  let _use_metrics: Bool
  let _no_write: Bool

  new iso create(coordinator: Coordinator,
    store: Store, stderr: StdStream, expected: (USize | None) = None,
    use_metrics: Bool, no_write: Bool)
  =>
    _coordinator = coordinator
    _store = store
    _stderr = stderr
    _expected = expected
    _use_metrics = use_metrics
    _no_write = no_write

  fun ref not_listening(listen: TCPListener ref) =>
    _coordinator.from_buffy_listener(listen, Failed)

  fun ref listening(listen: TCPListener ref) =>
    _coordinator.from_buffy_listener(listen, Ready)

  fun ref connected(listen: TCPListener ref): TCPConnectionNotify iso^ =>
    FromBuffyNotify(_coordinator, _store, _stderr, _expected, _use_metrics,
      _no_write)

class FromBuffyNotify is TCPConnectionNotify
  let _coordinator: Coordinator
  let _store: Store
  let _stderr: StdStream
  var _header: Bool = true
  var _count: USize = 0
  var _remaining: USize = 0
  var _expected: USize = 0
  var _expect_termination: Bool = false
  let _metrics: Metrics tag = Metrics
  let _use_metrics: Bool
  let _no_write: Bool
  var _closed: Bool = false

  new iso create(coordinator: Coordinator,
    store: Store, stderr: StdStream,
    expected: (USize | None),
    use_metrics: Bool, no_write: Bool)
  =>
    _coordinator = coordinator
    _store = store
    _stderr = stderr
    _use_metrics = use_metrics
    _no_write = no_write
    try
      if (expected as USize) > 0 then
        _expected = expected as USize
        _remaining = _expected
        _expect_termination = true
      end
    end

  fun ref received(conn: TCPConnection ref, data: Array[U8] iso,
    n: USize): Bool
  =>
    if _header then
      try
        _count = _count + 1
        if (_count == 1) and _use_metrics then
          _metrics.set_start(Time.nanos())
        end
        if _expect_termination then
          _remaining = _remaining - 1
        end

        let expect = Bytes.to_u32(data(0), data(1), data(2), data(3)).usize()

        conn.expect(expect)
        _header = false
      else
        _stderr.print("Blew up reading header from Buffy")
      end
    else
      if not _no_write then
        _store.received(consume data, Time.wall_to_nanos(Time.now()))
      end
      if _expect_termination and (_remaining <= 0) then
        if not _closed then
          _stderr.print(_count.string() + " expected messages received. " +
            "Terminating...")
          if _use_metrics then
            _metrics.set_end(Time.nanos(), _expected)
          end
          _coordinator.finished()
        end
        _closed = true
      else
        conn.expect(4)
        _header = true
      end
    end
    true

  fun ref accepted(conn: TCPConnection ref) =>
    conn.expect(4)
    _coordinator.connection_added(consume conn)


class ToDagonNotify is TCPConnectionNotify
  let _coordinator: WithDagonCoordinator
  let _stderr: StdStream
  var _header: Bool = true

  new iso create(coordinator: WithDagonCoordinator, stderr: StdStream) =>
    _coordinator = coordinator
    _stderr = stderr

  fun ref connect_failed(sock: TCPConnection ref) =>
    _coordinator.to_dagon_socket(sock, Failed)

  fun ref connected(sock: TCPConnection ref) =>
    sock.expect(4)
    _coordinator.to_dagon_socket(sock, Ready)

  fun ref received(conn: TCPConnection ref, data: Array[U8] iso,
    n: USize): Bool
  =>
    if _header then
      try
        let expect = Bytes.to_u32(data(0), data(1), data(2), data(3)).usize()
        conn.expect(expect)
        _header = false
      else
        _stderr.print("Blew up reading header from Buffy")
      end
    else
      try
        let decoded = ExternalMsgDecoder(consume data)
        match decoded
        | let d: ExternalShutdownMsg val =>
          _coordinator.finished()
        else
          _stderr.print("Unexpected data from Dagon")
        end
      else
        _stderr.print("Unable to decode message Dagon")
      end

      conn.expect(4)
      _header = true
    end
    true

//
// COORDINATE OUR STARTUP
//

primitive CoordinatorFactory
  fun apply(env: Env,
    store: Store,
    node_id: (String | None),
    to_dagon_addr: (Array[String] | None)): Coordinator ?
  =>
    if (node_id isnt None) and (to_dagon_addr isnt None) then
      let n = node_id as String
      let ph = to_dagon_addr as Array[String]
      let coordinator = WithDagonCoordinator(env, store, n)

      let tcp_auth = TCPConnectAuth(env.root as AmbientAuth)
      let to_dagon_socket = TCPConnection(tcp_auth,
        ToDagonNotify(coordinator, env.err),
        ph(0),
        ph(1))

      coordinator
    else
      WithoutDagonCoordinator(env, store)
    end

interface tag Coordinator
  be finished()
  be from_buffy_listener(listener: TCPListener, state: WorkerState)
  be connection_added(connection: TCPConnection)

primitive Waiting
primitive Ready
primitive Failed

type WorkerState is (Waiting | Ready | Failed)

actor WithoutDagonCoordinator is Coordinator
  let _env: Env
  let _store: Store
  var _from_buffy_listener: ((TCPListener | None), WorkerState) = (None, Waiting)
  let _connections: Array[TCPConnection] = Array[TCPConnection]

  new create(env: Env, store: Store) =>
    _env = env
    _store = store

  be finished() =>
    try
      let x = _from_buffy_listener._1 as TCPListener
      x.dispose()
    end
    for c in _connections.values() do c.dispose() end
    _store.dump()

  be from_buffy_listener(listener: TCPListener, state: WorkerState) =>
    _from_buffy_listener = (listener, state)
    if state is Failed then
      _env.err.print("Unable to open listener")
      listener.dispose()
    elseif state is Ready then
      _env.out.print("Listening for data")
    end

  be connection_added(c: TCPConnection) =>
    _connections.push(c)

actor WithDagonCoordinator is Coordinator
  let _env: Env
  let _store: Store
  var _from_buffy_listener: ((TCPListener | None), WorkerState) = (None, Waiting)
  var _to_dagon_socket: ((TCPConnection | None), WorkerState) = (None, Waiting)
  let _node_id: String
  let _connections: Array[TCPConnection] = Array[TCPConnection]

  new create(env: Env, store: Store, node_id: String) =>
    _env = env
    _store = store
    _node_id = node_id

  be finished() =>
    try
      let x = _from_buffy_listener._1 as TCPListener
      x.dispose()
    end
    for c in _connections.values() do c.dispose() end
    _store.dump()
    try
      let x = _to_dagon_socket._1 as TCPConnection
      x.writev(ExternalMsgEncoder.done_shutdown(_node_id))
      x.dispose()
    end

  be from_buffy_listener(listener: TCPListener, state: WorkerState) =>
    _from_buffy_listener = (listener, state)
    if state is Failed then
      _env.err.print("Unable to open listener")
      listener.dispose()
    elseif state is Ready then
      _env.out.print("Listening for data")
      _alert_ready_if_ready()
    end

  be to_dagon_socket(sock: TCPConnection, state: WorkerState) =>
    _to_dagon_socket = (sock, state)
    if state is Failed then
      _env.err.print("Unable to open dagon socket")
      sock.dispose()
    elseif state is Ready then
      _alert_ready_if_ready()
    end

  fun _alert_ready_if_ready() =>
    if (_to_dagon_socket._2 is Ready) and
       (_from_buffy_listener._2 is Ready)
    then
      try
        let x = _to_dagon_socket._1 as TCPConnection
        x.writev(ExternalMsgEncoder.ready(_node_id as String))
       end
    end

  be connection_added(c: TCPConnection) =>
    _connections.push(c)

///
/// RECEIVED MESSAGE STORE
///

actor Store
  let _received_file: (File | None)
  var _count: USize = 0

  new create(auth: AmbientAuth) =>
    _received_file =
      try
        let f = File(FilePath(auth, "received.txt"))
        f.set_length(0)
        f
      else
        None
      end

  be received(msg: Array[U8] iso, at: U64) =>
    match _received_file
      | let file: File => file.writev(
          FallorMsgEncoder.timestamp_raw(at, consume msg))
    end

  be dump() =>
    match _received_file
      | let file: File => file.dispose()
    end

//
// SHUTDOWN GRACEFULLY ON SIGTERM
//

class TermHandler is SignalNotify
  let _coordinator: Coordinator

  new iso create(coordinator: Coordinator) =>
    _coordinator = coordinator

  fun ref apply(count: U32): Bool =>
    _coordinator.finished()
    true

actor Metrics
  var start_t: U64 = 0
  var next_start_t: U64 = 0
  var end_t: U64 = 0

  be set_start(s: U64) =>
    if start_t != 0 then
      next_start_t = s
    else
      start_t = s
    end
    @printf[I32]("Metrics Start: %zu\n".cstring(), start_t)

  be set_end(e: U64, expected: USize) =>
    end_t = e
    let overall = (end_t - start_t).f64() / 1_000_000_000
    let throughput = ((expected.f64() / overall) / 1_000).usize()
    @printf[I32]("Metrics End: %zu\n".cstring(), end_t)
    @printf[I32]("Overall Time: %fs\n".cstring(), overall)
    @printf[I32]("Messages: %zu\n".cstring(), expected)
    @printf[I32]("Throughput: %zuk\n".cstring(), throughput)
    start_t = next_start_t
    next_start_t = 0
    end_t = 0