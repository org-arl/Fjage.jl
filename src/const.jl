export Services, ShellExecReq

"List of fjåge services."
module Services
  const SHELL = "org.arl.fjage.shell.Services.SHELL"
end

"Shell command execution request message."
@message "org.arl.fjage.shell.ShellExecReq" struct ShellExecReq
  cmd::Union{String,Nothing} = nothing
  script::Union{String,Nothing} = nothing
  args::Vector{String} = String[]
  ans::Bool = false
end
