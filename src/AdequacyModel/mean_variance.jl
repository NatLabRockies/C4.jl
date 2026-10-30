# This is adapted from the discussion of Welford's algorithm and parallel
# variance caluclation on Wikipedia:
# https://en.wikipedia.org/wiki/Algorithms_for_calculating_variance

mutable struct MeanVariance

    n::Int
    mean::Float64
    M2::Float64

    function MeanVariance()
        return new(0, 0., 0.)
    end

end

function update!(mv::MeanVariance, x::Float64)

    mv.n += 1

    old_mean = mv.mean
    mv.mean += (x - old_mean) / mv.n
    mv.M2 += (x - old_mean) * (x - mv.mean)

    return

end

mean_var(mv::MeanVariance) = mv.mean, mv.M2 / mv.n
mean_stderr(mv::MeanVariance) = mv.mean, sqrt(mv.M2) / mv.n

function merge!(mv1::MeanVariance, mv2::MeanVariance)

    n = mv1.n + mv2.n

    delta = mv2.mean - mv1.mean
    mv1.mean = (mv1.n * mv1.mean + mv2.n * mv2.mean) / n
    mv1.M2 = mv1.M2 + mv2.M2 + delta^2 * mv1.n * mv2.n / n

    mv1.n = n
    
    return

end

mutable struct MeanVarianceVector

    n::Int
    mean::Vector{Float64}
    M2::Vector{Float64}

    function MeanVarianceVector(size::Int)
        return new(0, zeros(size), zeros(size))
    end

end

function update!(mv::MeanVarianceVector, xs::Vector{Float64})

    length(mv.mean) == length(xs) || error("Vector lengths must match")

    mv.n += 1

    for (i, x) in enumerate(xs)
        old_mean = mv.mean[i]
        mv.mean[i] += (x - old_mean) / mv.n
        mv.M2[i] += (x - old_mean) * (x - mv.mean[i])
    end

    return

end

mean_var(mv::MeanVarianceVector) = mv.mean, mv.M2 / mv.n
mean_stderr(mv::MeanVarianceVector) = mv.mean, sqrt.(mv.M2) ./ mv.n

function merge!(mv1::MeanVarianceVector, mv2::MeanVarianceVector)

    length(mv1.mean) == length(mv2.mean) || error("Vector lengths must match")

    n = mv1.n + mv2.n

    for i in 1:length(mv1.mean)
        delta = mv2.mean[i] - mv1.mean[i]
        mv1.mean[i] = (mv1.n * mv1.mean[i] + mv2.n * mv2.mean[i]) / n
        mv1.M2[i] = mv1.M2[i] + mv2.M2[i] + delta^2 * mv1.n * mv2.n / n
    end

    mv1.n = n
    
    return

end
