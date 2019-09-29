using Test
using Fjage

# start fjåge

println("Starting fjåge...")
cp = replace(read(`find lib -name '*.jar'`, String), "\n" => ":")
master = open(`java -cp $cp org.arl.fjage.shell.GroovyBoot etc/initrc.groovy`)
sleep(2)

# tests

println("Starting tests...")

@testset "Fjage" begin

  gw = Gateway("localhost", 5081)
  @testset "Gateway" begin
    @test typeof(gw) <: Gateway
    @test typeof(gw.agentID) <: AgentID
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

  ShellExecReq = MessageClass("org.arl.fjage.shell.ShellExecReq")
  @testset "MessageClass" begin
    @test ShellExecReq <: Message
  end

  @testset "send & receive (gw)" begin
    send(gw, ShellExecReq(recipient=shell, cmd="ps"))
    rsp = receive(gw, 1000)
    @test typeof(rsp) <: Message
    @test rsp.performative == "AGREE"
  end

  @testset "send & receive (aid)" begin
    send(shell, ShellExecReq(cmd="ps"))
    rsp = receive(gw, 1000)
    @test typeof(rsp) <: Message
    @test rsp.performative == "AGREE"
  end

  @testset "request (gw)" begin
    rsp = request(gw, ShellExecReq(recipient=shell, cmd="ps"))
    @test typeof(rsp) <: Message
    @test rsp.performative == "AGREE"
  end

  @testset "request (aid)" begin
    rsp = request(shell, ShellExecReq(cmd="ps"))
    @test typeof(rsp) <: Message
    @test rsp.performative == "AGREE"
  end

  @testset "<< (aid, +)" begin
    rsp = shell << ShellExecReq(cmd="ps")
    @test typeof(rsp) <: Message
    @test rsp.performative == "AGREE"
  end

  dummy = agent(gw, "dummy")
  @testset "agent" begin
    @test typeof(dummy) <: AgentID
  end

  @testset "<< (aid, -)" begin
    rsp = dummy << ShellExecReq(cmd="ps")
    @test rsp == nothing
  end

  @testset "flush" begin
    send(gw, ShellExecReq(recipient=shell, cmd="ps"))
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
    send(ntf, ShellExecReq(cmd="ps"))
    msg = receive(gw, 1000)
    @test msg == nothing
  end

  @testset "subscribe (+)" begin
    subscribe(gw, ntf)
    send(ntf, ShellExecReq(cmd="ps"))
    msg = receive(gw, 1000)
    @test typeof(msg) <: ShellExecReq
  end

  @testset "unsubscribe" begin
    unsubscribe(gw, ntf)
    send(ntf, ShellExecReq(cmd="ps"))
    msg = receive(gw, 1000)
    @test msg == nothing
  end

  close(gw)

end

# stop fjåge

println("Stopping fjåge...")
kill(master)
