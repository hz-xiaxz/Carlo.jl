using Logging

"""Determine the number of bins in the rebin procedure. Rebinning will not be performed if the number of samples is smaller than `min_bin_count`."""
function calc_rebin_count(sample_count::Integer, min_bin_count::Integer = 10)::Integer
    return sample_count <= min_bin_count ? sample_count :
           (min_bin_count + round(cbrt(sample_count - min_bin_count)))
end

function calc_rebin_length(total_sample_count, rebin_length)
    if total_sample_count == 0
        return 1
    elseif rebin_length !== nothing
        return rebin_length
    else
        return total_sample_count ÷ calc_rebin_count(total_sample_count)
    end
end

"""
    iterate_measfile_observables(func, filenames, args...)

This helper function consecutively opens all ".meas.h5" files of a task. For each
observable in the file, it calls

    states[obs_key] = func(obs, get(states, obs_key, nothing), getindex.(args, obs_key)...)

Finally the dictionary `states` is returned. This construction allows `func` to only care about a single observable, simplifying the merging code.
"""
function iterate_measfile_observables(func::Func, filenames, args...) where {Func}
    states = Dict{Symbol,Any}()
    for filename in filenames
        h5open(filename, "r") do meas_file
            for obs_name in keys(meas_file["observables"])
                obs_key = Symbol(obs_name)
                obs = nothing
                try
                    obs = meas_file["observables"][obs_name]
                catch err
                    if err isa KeyError
                        @warn "$(obs_name): $(err). Skipping..."
                        continue
                    end
                    rethrow(err)
                end

                states[obs_key] =
                    func(obs, get(states, obs_key, nothing), getindex.(args, obs_key)...)
            end
        end
    end
    return states
end

function merge_results(
    ::Type{MC},
    taskdir::AbstractString;
    parameters::Dict{Symbol,Any},
    rebin_length::Union{Integer,Nothing} = get(parameters, :rebin_length, nothing),
    sample_skip::Integer = get(parameters, :rebin_sample_skip, 0),
) where {MC<:AbstractMC}
    merged_results = merge_results(
        JobTools.list_run_files(taskdir, "meas\\.h5");
        rebin_length,
        sample_skip,
    )

    evaluator = Evaluator(merged_results)
    register_evaluables(MC, evaluator, parameters)

    results = merge(
        merged_results,
        Dict(name => ResultObservable(obs) for (name, obs) in evaluator.evaluables),
    )

    write_results(results, taskdir * "/results.json", taskdir, parameters, Version(MC))
    return nothing
end

struct ObservableType{T,N}
    internal_bin_length::Int64
    shape::NTuple{N,Int64}
    total_sample_count::Int64
end

get_type(::ObservableType{T}) where {T} = T

function add_samples!(acc, acc², samples, sample_skip)
    for value in Iterators.drop(eachslice(samples; dims = ndims(samples)), sample_skip)
        add_sample!(acc, value)
        add_sample!(abs2, acc², value)
    end
    return nothing
end

function merge_results(
    filenames::AbstractArray{<:AbstractString};
    rebin_length::Union{Integer,Nothing},
    sample_skip::Integer = 0,
)
    obs_types = iterate_measfile_observables(filenames) do obs_group, state
        internal_bin_length = read(obs_group, "bin_length")
        sample_size = size(obs_group["samples"])

        # TODO: compat for v0.1.5 format. Remove in v0.3
        if length(sample_size) == 2 &&
           sample_size[1] == 1 &&
           !haskey(attributes(obs_group["samples"]), "v0.2_format")
            sample_size = (sample_size[2],)
        end

        shape = sample_size[1:end-1]
        nsamples = max(0, sample_size[end] - sample_skip)

        type = eltype(obs_group["samples"])

        if isnothing(state)
            return ObservableType{type,length(shape)}(internal_bin_length, shape, nsamples)
        end
        if shape != state.shape
            error("Observable shape ($shape) does not agree between runs ($(state.shape))")
        end

        return ObservableType{promote_type(get_type(state), type),length(state.shape)}(
            state.internal_bin_length,
            state.shape,
            state.total_sample_count + nsamples,
        )
    end

    binned_obs =
        iterate_measfile_observables(filenames, obs_types) do obs_group, state, obs_type
            if state === nothing
                binsize = calc_rebin_length(obs_type.total_sample_count, rebin_length)
                state = (;
                    acc = Accumulator{get_type(obs_type)}(binsize, obs_type.shape),
                    acc² = Accumulator{real(get_type(obs_type))}(binsize, obs_type.shape),
                )
            end

            samples = read(obs_group, "samples")
            # TODO: compat for v0.1.5 format. Remove in v0.3
            if !haskey(attributes(obs_group["samples"]), "v0.2_format")
                samples = reshape(samples, Int.(obs_type.shape)..., :)
            end

            add_samples!(state.acc, state.acc², samples, sample_skip)

            return state
        end

    return Dict{Symbol,ResultObservable}(
        obs_name => begin
            μ = mean(obs.acc)
            σ = std_of_mean(obs.acc)

            no_rebinning_σ =
                sqrt.(
                    max.(0, mean(obs.acc²) .- abs2.(μ)) ./
                    (obs.acc.bin_length * num_bins(obs.acc) - 1)
                )
            autocorrelation_time = 0.5 .* (σ ./ no_rebinning_σ) .^ 2

            # broadcasting promotes 0-dim arrays to scalar, which we do not want
            ensure_array(x::Number) = fill(x)
            ensure_array(x::AbstractArray) = x

            ResultObservable(
                obs_types[obs_name].internal_bin_length,
                obs.acc.bin_length,
                μ,
                σ,
                ensure_array(autocorrelation_time),
                bins(obs.acc),
            )
        end for (obs_name, obs) in binned_obs if num_bins(obs.acc) > 0
    )
end
