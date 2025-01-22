export Services, ShellExecReq

"List of fjåge services."
module Services
  const SHELL = "org.arl.fjage.shell.Services.SHELL"
end

"Shell command execution request message."
@message "org.arl.fjage.shell.ShellExecReq" struct ShellExecReq
  command::Union{String,Nothing} = nothing
  ans::Bool = false
end
