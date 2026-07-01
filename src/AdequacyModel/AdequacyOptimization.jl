struct AdequacyOptimization

    model::JuMP.Model

    unserved::Vector{JuMP.VariableRef} # T
    charge::Matrix{JuMP.VariableRef} # SxT
    discharge::Matrix{JuMP.VariableRef} # SxT
    energy::Matrix{JuMP.VariableRef} # SxT

    grid_balance::Vector{JuMP_LessThanConstraintRef} # T, re-parametrized each sample
    storage_balance::Matrix{JuMP_EqualToConstraintRef} # SxT

    generator_nexttransition::Vector{Int} # G (internal state for outage sampling)

    function AdequacyOptimization(prob::AdequacyParams, optimizer)

        m = JuMP.direct_model(optimizer)

        S = prob.n_storages
        T = prob.n_timesteps

        @variable(m, unserved[1:T], lower_bound=0)

        @variable(m, charge[s in 1:S, 1:T],
                  lower_bound=0, upper_bound=prob.storages[s].power_capacity)

        @variable(m, discharge[s in 1:S, 1:T],
                  lower_bound=0, upper_bound=prob.storages[s].power_capacity)

        @variable(m, energy[s in 1:S, 1:T],
                  lower_bound=0, upper_bound=prob.storages[s].energy_capacity)

        @objective(m, Min, sum(unserved))

        # RHS will be updated each sample to supply[t] - demand[t]
        @constraint(m, grid_balance[t in 1:T],
            sum(charge[s, t] for s in 1:S) - sum(discharge[s, t] for s in 1:S)
            - unserved[t] <= 0)

        @constraint(m, storage_balance[t in 1:T, s in 1:S],
            energy[s,t] == (t == 1 ? energy[s, T] : energy[s, t-1])
                + charge[s,t] * prob.storages[s].charge_eff
                - discharge[s,t] / prob.storages[s].discharge_eff)

         gen_nexttrans = Vector{Int}(undef, prob.n_generators)

      return new(m, unserved, charge, discharge, energy,
                 grid_balance, storage_balance, gen_nexttrans)

    end

end

update_surplus!(opt::AdequacyOptimization, t::Int, surplus::Float64) =
    set_normalized_rhs(opt.grid_balance[t], surplus)

function solve!(opt::AdequacyOptimization)

    JuMP.optimize!(opt.model)

    if JuMP.termination_status(opt.model) != JuMP.OPTIMAL
        println(JuMP.termination_status(opt.model))
        println(opt.model)
        error("Problem did not solve to optimality")
    end

end

unserved(opt::AdequacyOptimization) = value.(opt.unserved)

grid_dual(opt::AdequacyOptimization) = -shadow_price.(opt.grid_balance)

stor_power_dual(opt::AdequacyOptimization) =
    - sum(shadow_price.(UpperBoundRef.(opt.charge)), dims=2, init=0.) -
    sum(shadow_price.(UpperBoundRef.(opt.discharge)), dims=2, init=0.)

stor_energy_dual(opt::AdequacyOptimization) =
    -sum(shadow_price.(UpperBoundRef.(opt.energy)), dims=2, init=0.)

function sample_surplus!(
    opt::AdequacyOptimization, prob::AdequacyParams, sample_idx::Int)

    rng = Philox4x((sample_idx, sample_idx), 10)

    # TODO: Update counter predictably based on g (generator name hash?) and t.
    #       For now we just use automatic incrementing

    # Initialize transitions away from starting states
    for g in 1:prob.n_generators

        lambda = prob.generators_lambda[1, g]
        mu = prob.generators_mu[1, g]

        if rand(rng) < mu / (lambda + mu) # unit starts available
            unavailable_probs = view(prob.generators_lambda, :, g)
            opt.generator_nexttransition[g] =
                randtransitiontime(rng, unavailable_probs, 1, prob.n_timesteps)
        else # unit starts unavailable
            available_probs = view(prob.generators_mu, :, g)
            opt.generator_nexttransition[g] =
                -randtransitiontime(rng, available_probs, 1, prob.n_timesteps)
        end

    end

    for t in 1:prob.n_timesteps

        surplus = -prob.demand[t]

        for g in 1:prob.n_generators

            if opt.generator_nexttransition[g] > 0 # previously available

                transitioning = t == opt.generator_nexttransition[g]

                if transitioning

                    available_probs = view(prob.generators_mu, :, g)
                    opt.generator_nexttransition[g] =
                        -randtransitiontime(rng, available_probs, t, prob.n_timesteps)

                else

                    surplus += prob.generators_capacity[g,t]

                end

            else # previously unavailable

                transitioning = t == -opt.generator_nexttransition[g]

                if transitioning

                    unavailable_probs = view(prob.generators_lambda, :, g)
                    # 1/3 of init time spent here - why 3x more than above randtransitiontime call?
                    # Shouldn't they happen equally frequently?
                     opt.generator_nexttransition[g] =
                        randtransitiontime(rng, unavailable_probs, t, prob.n_timesteps)
                    surplus += prob.generators_capacity[g,t]

                end

            end

        end

        update_surplus!(opt, t, surplus)

    end

    return

end

# Adapted from PRAS
function randtransitiontime(
    rng::AbstractRNG, p::AbstractVector{Float64}, t_now::Int, t_last::Int
)

    cdf = 0.
    p_noprevtransition = 1.

    x = rand(rng)
    t = t_now + 1

    while t <= t_last
        p_t = p[t]
        cdf += p_noprevtransition * p_t
        x < cdf && return t
        p_noprevtransition *= (1. - p_t)
        t += 1
    end

    return t_last + 1

end
