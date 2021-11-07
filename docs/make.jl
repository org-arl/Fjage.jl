using Documenter

push!(LOAD_PATH,"../src/")
using Fjage

makedocs(
  sitename = "Fjage.jl",
  format = Documenter.HTML(prettyurls = false),
  pages = Any[
    "Home" => "index.md",
    "Manual" => Any[
      "Fjage.md",
      "gw.md",
      "container.md",
      "aid.md",
      "msg.md",
      "const.md"
    ]
  ]
)

deploydocs(
  repo = "github.com/org-arl/Fjage.jl.git",
  branch = "gh-pages",
  devbranch = "master",
  devurl = "dev",
  versions = ["stable" => "v^", "v#.#", "dev" => "dev"]
)
