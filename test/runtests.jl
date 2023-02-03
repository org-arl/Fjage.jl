using Test
using Fjage

# start fjåge

println("Starting fjåge...")
cp = replace(read(`find lib -name '*.jar'`, String), "\n" => ":")
master = open(`java -cp $cp org.arl.fjage.shell.GroovyBoot etc/initrc.groovy`)
sleep(2)

# tests

println("Starting tests...")
try

  @testset "Fjage" begin

    gw = Gateway("localhost", 5081)
    @testset "Gateway" begin
      @test typeof(gw) <: Gateway
      @test typeof(gw.agentID) <: AgentID
      @test AgentID(gw) isa AgentID
    end

    shell = agentforservice(gw, "org.arl.fjage.shell.Services.SHELL")
    @testset "agentforservice (+)" begin
      @test typeof(shell) <: AgentID
      @test shell.name == "shell"
      @test shell.istopic == false
    end

    @testset "agentforservice (-)" begin
      dummy = agentforservice(gw, "org.arl.dummy.Services.DUMMY")
      @test dummy == nothing
    end

    @testset "agentsforservice (+)" begin
      alist = agentsforservice(gw, "org.arl.fjage.shell.Services.SHELL")
      @test typeof(alist) <: Array
      @test length(alist) == 1
      @test typeof(alist[1]) <: AgentID
      @test alist[1].name == "shell"
      @test alist[1].istopic == false
    end

    @testset "agentsforservice (-)" begin
      alist = agentsforservice(gw, "org.arl.dummy.Services.DUMMY")
      @test typeof(alist) <: Array
      @test length(alist) == 0
    end

    MyAbstractReq = AbstractMessageClass(@__MODULE__, "org.arl.fjage.test.MyAbstractReq")
    MyReq = MessageClass(@__MODULE__, "org.arl.fjage.test.MyReq", MyAbstractReq)
    @testset "MessageClass" begin
      @test MyAbstractReq <: Message
      @test MyReq <: Message
      @test MyReq <: MyAbstractReq
      @test isa(MyAbstractReq(), MyAbstractReq)
      @test isa(MyReq(), MyAbstractReq)
    end

    @testset "send & receive (gw)" begin
      flush(gw)
      send(gw, ShellExecReq(recipient=shell, cmd="1+2"))
      rsp = receive(gw, 1000)
      @test typeof(rsp) <: Message
      @test rsp.performative == "AGREE"
    end

    @testset "send & receive (aid)" begin
      flush(gw)
      send(shell, ShellExecReq(cmd="1+2"))
      rsp = receive(gw, 1000)
      @test typeof(rsp) <: Message
      @test rsp.performative == "AGREE"
    end

    @testset "request (gw)" begin
      flush(gw)
      rsp = request(gw, ShellExecReq(recipient=shell, cmd="1+2"))
      @test typeof(rsp) <: Message
      @test rsp.performative == "AGREE"
    end

    @testset "request (aid)" begin
      flush(gw)
      rsp = request(shell, ShellExecReq(cmd="1+2"))
      @test typeof(rsp) <: Message
      @test rsp.performative == "AGREE"
    end

    @testset "<< (aid, +)" begin
      flush(gw)
      rsp = shell << ShellExecReq(cmd="1+2")
      @test typeof(rsp) <: Message
      @test rsp.performative == "AGREE"
    end

    dummy = agent(gw, "dummy")
    @testset "agent" begin
      @test typeof(dummy) <: AgentID
    end

    @testset "<< (aid, -)" begin
      rsp = dummy << ShellExecReq(cmd="1+2")
      @test rsp == nothing
    end

    @testset "flush" begin
      flush(gw)
      send(gw, ShellExecReq(recipient=shell, cmd="1+2"))
      sleep(1)
      flush(gw)
      rsp = receive(gw, 1000)
      @test rsp == nothing
    end

    ntf = topic(gw, "broadcast")
    @testset "topic" begin
      @test typeof(ntf) <: AgentID
    end

    @testset "subscribe (-)" begin
      flush(gw)
      send(ntf, ShellExecReq(cmd="1+2"))
      msg = receive(gw, 1000)
      @test msg == nothing
    end

    @testset "subscribe (+)" begin
      flush(gw)
      subscribe(gw, ntf)
      send(ntf, ShellExecReq(cmd="1+2"))
      msg = receive(gw, 1000)
      @test typeof(msg) <: ShellExecReq
    end

    @testset "receive (filt, +)" begin
      flush(gw)
      send(ntf, ShellExecReq(cmd="1+2"))
      msg = receive(gw, ShellExecReq, 1000)
      @test typeof(msg) <: ShellExecReq
    end

    UnknownReq = MessageClass(@__MODULE__, "org.arl.fjage.shell.UnknownReq")
    @testset "receive (filt, -)" begin
      flush(gw)
      send(ntf, ShellExecReq(cmd="1+2"))
      msg = receive(gw, UnknownReq, 1000)
      @test msg == nothing
    end

    @testset "unsubscribe" begin
      unsubscribe(gw, ntf)
      flush(gw)
      send(ntf, ShellExecReq(cmd="1+2"))
      msg = receive(gw, 1000)
      @test msg == nothing
    end

    code = "
      container.add 'a', new org.arl.fjage.Agent() {
        int x = 1
        int y = 2
        String s = 'hello'
        double[] f = [1.0, 2.0]
        void init() {
          add new org.arl.fjage.param.ParameterMessageBehavior()
        }
        int getZ(int ndx) {
          if (ndx == 1) return y
          return 0
        }
        void setZ(int ndx, int v) {
          if (ndx == 1) y = v
        }
        void setF(List x) {
          f = x as double[]
        }
      }"
    shell << ShellExecReq(cmd=code)
    sleep(2)
    a = agent(gw, "a")

    @testset "parameter (get)" begin
      flush(gw)
      @test shell.language == "Groovy"
      @test a.x == 1
      @test a.s == "hello"
      @test a.f == [1.0, 2.0]
      @test a.b == nothing
      @test a[1].z == 2
      @test a[2].z == 0
    end

    @testset "parameter (set)" begin
      flush(gw)
      a.x = 7
      @test a.x == 7
      a.s = "hi"
      @test a.s == "hi"
      a.f = [2.1, 3.4]
      @test a.f == [2.1, 3.4]
      a[1].z = 14
      @test a[1].z == 14
    end

    @testset "reconnect" begin
      flush(gw)
      close(gw.sock[])
      send(gw, ShellExecReq(recipient=shell, cmd="1+2"))
      rsp = receive(gw, 1000)
      @test rsp === nothing
      for i ∈ 1:10
        send(gw, ShellExecReq(recipient=shell, cmd="1+2"))
        rsp = receive(gw, 1000)
        rsp === nothing || break
        sleep(1.0)
      end
      @test typeof(rsp) <: Message
      @test rsp.performative == "AGREE"
    end

    close(gw)

  end

finally

# stop fjåge

  println("Stopping fjåge...")
  kill(master)

end

@testset "CoroutineBehavior" begin
  c = Container()
  start(c)

  @agent struct MyAgent; end
  a = MyAgent()
  add(c, a)

  @testset "delay" begin
    # Test that delay indeed delays for at least as long as promised
    dt = 100
    t = zeros(Int, 10)
    b = CoroutineBehavior() do a, b
      for i in eachindex(t)
        t[i] = currenttimemillis(a)
        delay(b, dt)
      end
    end
    add(a, b)
    sleep(1.0 + length(t) * dt * 1e-3)

    @test done(b)
    @test all(diff(t) .>= dt)
    @test !(b in a._behaviors)
  end

  @testset "stop" begin
    # Test that CoroutineBehaviors can be stopped during delays
    flag = false
    b = CoroutineBehavior() do a, b
      delay(b, 1000)
      flag = true
    end
    add(a,b)
    stop(b)
    sleep(0.1)
    @test !flag
    @test done(b)
    @test !(b in a._behaviors)
  end

  @testset "lock" begin
    # Test that CoroutineBehaviors lock the agent while they are running
    dt = 1000
    t0 = currenttimemillis(a)
    t1 = -1
    add(a, CoroutineBehavior((a,b) -> sleep(dt*1e-3)))
    add(a, OneShotBehavior((a,b) -> t1 = currenttimemillis(a)))
    sleep(0.5 + dt*1e-3)
    @show t0, t1
    @test t1 - t0 > dt
  end
end