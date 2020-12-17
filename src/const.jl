export Services, ShellExecReq

module Services
  const SHELL = "org.arl.fjage.shell.Services.SHELL"
end

"Shell command execution request message."
ShellExecReq = MessageClass(@__MODULE__, "org.arl.fjage.shell.ShellExecReq")
