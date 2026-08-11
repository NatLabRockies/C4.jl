using Documenter, C4

makedocs(
    sitename="C4.jl", remotes=nothing,
    format = Documenter.HTML(assets = ["assets/datatree.css"]),
    pages = [
        "Home" => "index.md",
        "Installation" => "installation.md",
        "Quick Start" => "quickstart.md",
        "Input Data Format" => "inputdata.md",
        "Model Architecture" => "architecture.md"]
)
