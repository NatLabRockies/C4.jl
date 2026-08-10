# Installation

## Installing Julia

C4 is implemented in the
[Julia programming language](https://julialang.org/)
and requires a recent
version of the Julia interpreter/compiler to be installed on the user's
computer. The appropriate version for your operating system can be obtained via
the [Downloads page](https://julialang.org/downloads/) of the official Julia
website.

## Installing C4 and its Julia dependencies

Once Julia is installed, its built-in package manager can automatically
download and install C4 and the other Julia packages it depends on. The Julia
documentation includes more complete instructions on
[using the package manager](https://docs.julialang.org/en/v1/stdlib/Pkg/),
but after entering the `pkg>` package management prompt (by pressing the `]`
key from the main Julia prompt), the following command should trigger the
full installation:

```
pkg> add https://github.com/NatLabRockies/C4.jl.git
```

If a specific version of the tool is desired, you can request a specific
branch or tag from the repository where the C4 code is stored. For example,
the following would install the exact version of the code used for a specific
study:

```
pkg> add https://github.com/NatLabRockies/C4.jl.git#2025-srptva-flexstor
```

## Installing a MILP optimization Solver

C4 is built on top of [JuMP](https://jump.dev/) and formulates its capacity
expansion and production cost problems as mixed-integer linear programs
(MILPs). It relies on a user-provided external optimization solver program
to solve these problems. Instructions and options for installing a
JuMP-compatible MILP solver are available in the
[JuMP documentation](https://jump.dev/JuMP.jl/stable/installation/#Install-a-solver).

While any JuMP-compatible MILP solver should work, the C4 developers suggest
[HiGHS](https://highs.dev/) as a quick and easy way to get started. HiGHS is
free and open-source software that can be fully installed with a single Julia
package management command:

```
pkg> add HiGHS
```

For solving larger problems. commerical proprietary solvers such as
[Gurobi](https://www.gurobi.com/) may offer faster solutions.
While installing the [Gurobi.jl package](https://github.com/jump-dev/Gurobi.jl)
(via `add Gurobi`) will provide the executable binary files needed to run
Gurobi, you will need to independently obtain a Gurobi license before the
installed software will run.
