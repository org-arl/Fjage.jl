# tests for standalone containers, agents and behaviors (no Java master needed)

using Test
using Fjage

# wait for a predicate to become true, with a generous timeout for slow CI machines
waitfor(pred; timeout=10.0) = timedwait(() -> pred() === true, timeout; pollint=0.01) === :ok

@message "org.arl.fjage.test.CTMsg" struct CTMsg
  x::Int = 0
end

@message "org.arl.fjage.test.CTReq" Performative.REQUEST struct CTReq end

@agent struct CTAgent end

# agent that replies AGREE to any CTReq it receives
@agent struct CTEchoAgent end

function Fjage.processrequest(a::CTEchoAgent, req::CTReq)
  rsp = CTMsg(x=42)
  rsp.recipient = req.sender
  rsp.inReplyTo = req.messageID
  rsp.performative = Performative.AGREE
  rsp
end

# agent that counts every CTMsg reaching its default message handler
@agent struct CTSinkAgent
  count::Threads.Atomic{Int} = Threads.Atomic{Int}(0)
end

function Fjage.processmessage(a::CTSinkAgent, msg)
  msg isa CTMsg && Threads.atomic_add!(a.count, 1)
  nothing
end

@states CT_S1 CT_S2

@fsm struct CTFSM
  initialstate = CT_S1
  log::Vector{Symbol} = Symbol[]
end

function Fjage.onenter(a::Agent, b::CTFSM, ::typeof(CT_S1))
  push!(b.log, :S1)
  after(b, 0.05) do
    nextstate!(b, CT_S2)
  end
end

function Fjage.onenter(a::Agent, b::CTFSM, ::typeof(CT_S2))
  push!(b.log, :S2)
  after(b, 0.05) do
    stop(b)
  end
end

function ctsend(from::Agent, to, x)
  msg = CTMsg(x=x)
  msg.recipient = to isa AgentID ? to : AgentID(to)
  send(from, msg)
end

@testset "StandaloneContainer" begin
  c = Container()
  start(c)
  @test isrunning(c)
  a = CTAgent()
  add(c, "cta", a)
  @test containsagent(c, AgentID("cta"))
  @test canlocateagent(c, AgentID("cta"))
  @test AgentID(a) == AgentID("cta")
  register(a, "org.arl.fjage.test.Services.CT")
  @test agentforservice(a, "org.arl.fjage.test.Services.CT") == AgentID("cta")
  @test AgentID("cta") ∈ agentsforservice(a, "org.arl.fjage.test.Services.CT")
  @test agentforservice(a, "org.arl.fjage.test.Services.DUMMY") === nothing
  kill(c, "cta")
  @test !containsagent(c, AgentID("cta"))
  shutdown(c)
  @test !isrunning(c)
end

@testset "OneShotBehavior" begin
  c = Container()
  start(c)
  a = CTAgent()
  add(c, a)
  trace = Symbol[]
  b = OneShotBehavior((a, b) -> push!(trace, :action))
  b.onstart = (a, b) -> push!(trace, :onstart)
  b.onend = (a, b) -> push!(trace, :onend)
  add(a, b)
  @test waitfor(() -> done(b))
  @test trace == [:onstart, :action, :onend]
  @test !(b in a._behaviors)
  shutdown(c)
end

@testset "CyclicBehavior block/restart/stop" begin
  c = Container()
  start(c)
  a = CTAgent()
  add(c, a)
  n = Threads.Atomic{Int}(0)
  b = CyclicBehavior((a, b) -> Threads.atomic_add!(n, 1))
  add(a, b)
  @test waitfor(() -> n[] > 10)
  # block pauses the behavior
  block(b)
  @test isblocked(b)
  sleep(0.2)
  n1 = n[]
  sleep(0.2)
  @test n[] == n1
  # block is idempotent: a second block must not replace the condition
  cond = b.block
  block(b)
  @test b.block === cond
  # restart resumes the behavior
  restart(b)
  @test waitfor(() -> n[] > n1)
  # restart on an unblocked behavior is a no-op
  restart(b)
  @test !isblocked(b)
  # timed block auto-restarts
  block(b, 100)
  @test isblocked(b)
  @test waitfor(() -> !isblocked(b))
  n2 = n[]
  @test waitfor(() -> n[] > n2)
  # stop terminates the behavior, even while blocked
  block(b)
  stop(b)
  @test waitfor(() -> done(b) && !(b in a._behaviors))
  shutdown(c)
end

@testset "WakerBehavior" begin
  c = Container()
  start(c)
  a = CTAgent()
  add(c, a)
  fired = Ref(-1)
  t0 = currenttimemillis(a)
  b = WakerBehavior((a, b) -> (fired[] = currenttimemillis(a) - t0), 500)
  add(a, b)
  sleep(0.1)
  @test fired[] == -1
  @test waitfor(() -> done(b))
  @test fired[] >= 400
  # stopping a waker mid-block must terminate it promptly and without error
  b2 = WakerBehavior((a, b) -> nothing, 60000)
  add(a, b2)
  @test waitfor(() -> isblocked(b2))
  stop(b2)
  @test waitfor(() -> done(b2) && !(b2 in a._behaviors))
  shutdown(c)
end

@testset "TickerBehavior" begin
  c = Container()
  start(c)
  a = CTAgent()
  add(c, a)
  b = TickerBehavior((a, b) -> nothing, 50)
  add(a, b)
  @test waitfor(() -> tickcount(b) ≥ 5)
  stop(b)
  @test waitfor(() -> done(b) && !(b in a._behaviors))
  shutdown(c)
end

@testset "PoissonBehavior" begin
  c = Container()
  start(c)
  a = CTAgent()
  add(c, a)
  b = PoissonBehavior((a, b) -> nothing, 20)
  add(a, b)
  @test waitfor(() -> tickcount(b) ≥ 3)
  stop(b)
  @test waitfor(() -> done(b) && !(b in a._behaviors))
  shutdown(c)
end

@testset "block/restart stress" begin
  c = Container()
  start(c)
  a = CTAgent()
  add(c, a)
  n = Threads.Atomic{Int}(0)
  b = CyclicBehavior((a, b) -> Threads.atomic_add!(n, 1))
  add(a, b)
  # hammer block/restart (untimed and timed) from concurrent tasks; the behavior
  # must survive without hanging or crashing, and still run afterwards
  hammers = [Threads.@spawn begin
      for _ in 1:250
        block(b)
        yield()
        restart(b)
        block(b, 1)
        yield()
        restart(b)
      end
    end for _ in 1:4]
  @test waitfor(() -> all(istaskdone, hammers); timeout=60.0)
  @test all(t -> !istaskfailed(t), hammers)
  restart(b)
  n1 = n[]
  @test waitfor(() -> n[] > n1)
  stop(b)
  @test waitfor(() -> done(b))
  shutdown(c)
end

@testset "FSMBehavior" begin
  c = Container()
  start(c)
  a = CTAgent()
  add(c, a)
  b = CTFSM()
  add(a, b)
  @test waitfor(() -> done(b))
  @test b.log == [:S1, :S2]
  @test state(b) == Fjage.FINAL
  # reset makes the FSM reusable
  reset(b)
  @test state(b) == Fjage.INIT
  empty!(b.log)
  add(a, b)
  @test waitfor(() -> done(b))
  @test b.log == [:S1, :S2]
  shutdown(c)
end

@testset "agent messaging" begin
  c = Container()
  start(c)
  a1 = CTAgent()
  a2 = CTAgent()
  add(c, "cta1", a1)
  add(c, "cta2", a2)
  # send & receive (blocking, with filter); a receive with a non-matching filter
  # must time out while a matching receive gets the message
  rcv1 = Threads.@spawn receive(a2, CTReq, 1000)
  rcv2 = Threads.@spawn receive(a2, CTMsg, 5000)
  sleep(0.2)
  ctsend(a1, "cta2", 7)
  rsp = fetch(rcv2)
  @test rsp isa CTMsg
  @test rsp.x == 7
  @test rsp.sender == AgentID("cta1")
  @test fetch(rcv1) === nothing
  # topics
  t = topic("ct-news")
  subscribe(a2, t)
  rcv = Threads.@spawn receive(a2, CTMsg, 5000)
  sleep(0.2)
  ctsend(a1, t, 9)
  rsp = fetch(rcv)
  @test rsp isa CTMsg
  @test rsp.x == 9
  unsubscribe(a2, t)
  rcv = Threads.@spawn receive(a2, CTMsg, 500)
  sleep(0.2)
  ctsend(a1, t, 10)
  @test fetch(rcv) === nothing
  shutdown(c)
end

@testset "request & reply" begin
  c = Container()
  start(c)
  a1 = CTAgent()
  echo = CTEchoAgent()
  add(c, "cta1", a1)
  add(c, "ctecho", echo)
  req = CTReq()
  req.recipient = AgentID("ctecho")
  rsp = request(a1, req, 5000)
  @test rsp isa CTMsg
  @test rsp.performative == Performative.AGREE
  @test rsp.x == 42
  # unhandled requests are answered with NOT_UNDERSTOOD by the default handler
  req = CTReq()
  req.recipient = AgentID("cta1")
  rsp = request(echo, req, 5000)
  @test rsp !== nothing
  @test rsp.performative == Performative.NOT_UNDERSTOOD
  shutdown(c)
end

@testset "message flood (issue #36)" begin
  c = Container()
  start(c)
  a1 = CTAgent()
  sink = CTSinkAgent()
  add(c, "cta1", a1)
  add(c, "ctsink", sink)
  # concurrently flood the sink with messages while a competing high-priority
  # receive() loop registers and deregisters a listener; every message must be
  # consumed exactly once — by receive() or by the default handler — with none
  # lost or deadlocked (issue #36: put! into an abandoned listener channel)
  N = 100
  recvd = Threads.Atomic{Int}(0)
  stopflag = Ref(false)
  receiver = Threads.@spawn begin
    while !stopflag[] && recvd[] + sink.count[] < N
      m = receive(sink, CTMsg, 100)
      m === nothing || Threads.atomic_add!(recvd, 1)
    end
  end
  sender = Threads.@spawn begin
    for i in 1:N
      ctsend(a1, "ctsink", i)
      i % 5 == 0 && sleep(0.001)
    end
  end
  ok = waitfor(() -> recvd[] + sink.count[] == N; timeout=60.0)
  stopflag[] = true
  @test ok
  @test waitfor(() -> istaskdone(sender) && istaskdone(receiver); timeout=30.0)
  @test recvd[] + sink.count[] == N
  shutdown(c)
end

@testset "MessageBehavior stop mid-stream (issue #36)" begin
  c = Container()
  start(c)
  a1 = CTAgent()
  a2 = CTAgent()
  add(c, "cta1", a1)
  add(c, "cta2", a2)
  seen = Threads.Atomic{Int}(0)
  b = MessageBehavior() do a, b, msg
    Threads.atomic_add!(seen, 1)
    sleep(0.02)   # keep the listener channel busy
  end
  add(a2, b)
  sleep(0.1)
  flood = Threads.@spawn begin
    for i in 1:100
      ctsend(a1, "cta2", i)
      sleep(0.005)
    end
  end
  @test waitfor(() -> seen[] ≥ 5)
  # stopping the behavior while its channel is full used to deadlock the agent's
  # message delivery (put! into a full channel under the _processmsg lock)
  stop(b)
  @test waitfor(() -> !(b in a2._behaviors); timeout=30.0)
  # the agent must remain responsive after the behavior is gone
  req = CTReq()
  req.recipient = AgentID("cta2")
  rsp = request(a1, req, 5000)
  @test rsp !== nothing
  @test rsp.performative == Performative.NOT_UNDERSTOOD
  wait(flood)
  shutdown(c)
end

@testset "filtered MessageBehavior" begin
  c = Container()
  start(c)
  a1 = CTAgent()
  a2 = CTAgent()
  add(c, "cta1", a1)
  add(c, "cta2", a2)
  reqs = Threads.Atomic{Int}(0)
  b = MessageBehavior(CTReq) do a, b, msg
    Threads.atomic_add!(reqs, 1)
  end
  add(a2, b)
  sleep(0.1)
  ctsend(a1, "cta2", 1)      # does not match the filter
  req = CTReq()
  req.recipient = AgentID("cta2")
  send(a1, req)
  @test waitfor(() -> reqs[] == 1)
  sleep(0.2)
  @test reqs[] == 1
  stop(b)
  @test waitfor(() -> !(b in a2._behaviors))
  shutdown(c)
end
