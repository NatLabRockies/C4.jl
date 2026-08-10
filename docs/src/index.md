# C4.jl

C4 is an integrated tool for power system capacity expansion, resource
adequacy assessment, and production cost modelling. Unlike most capacity
expansion frameworks, it designs and dispatches generation portfolios subject
to direct constraints on probabilistic adequacy risk (expected unserved
energy), eliminating the need for capacity credits and planning reserve
margin heuristics.

As a platform for capacity expansion methods research, C4 implements a number
of innovating mathematical formulations to capture consequential adequacy
factors, such as:

- Dynamically-generated expected unserved energy (EUE) cutting planes to design
  systems to an exact probabilitic adequacy criterion
- Adaptive stress period planning to iteratively identify and plan against time
  periods that drive overall adequacy investment requirements ([technical report]())
- Sparse storage chronology to efficiently represent storage state-of-charge
  dynamics over long time horizons ([journal paper](), [open-access preprint]())
