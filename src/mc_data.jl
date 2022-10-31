using HDF5
using Random

mutable struct MCData{RNG <: Random.AbstractRNG}
    sweeps::Int64
    thermalization_sweeps::Int64

    rng::RNG
    measure::Measurements
end

rand!(data::MCData, X) = rand!(rng = data.rng, X)

is_thermalized(data::MCData) = data.sweeps >= data.thermalization_sweeps

function MCData{RNG}(parameters::Dict) where {RNG}
    measure = Measurements(parameters["binsize"])
    register_observable!(data.measure, "_ll_checkpoint_read_time", 1, 1)
    register_observable!(data.measure, "_ll_checkpoint_write_time", 1, 1)
    

    if haskey(parameters, "seed")
        rng = RNG(parameters["seed"])
    else
        rng = RNG()
    end

    return MCData(
        sweeps = 0,
        thermalization_sweeps = parameters["thermalization"],
        rng = rng,
        measure = measure
    )
end

function write_measurements!(data::MCData, meas_file::HDF5.Group)
    write_measurements!(data.measure, meas_file["observables"])
    # TODO: write version    

    return nothing
end

function write_checkpoint(data::MCData, check_file::HDF5.Group)
    write_rng_checkpoint!(data.rng, check_file["random_number_generator"])
    write_checkpoint!(data.measure, check_file["measurements"])

    check_file["thermalization_sweeps"] = min(data.sweep, data.thermalization)
    check_file["sweeps"] = data.sweep - min(data.sweep, data.thermalization)

    return nothing
end

function read_checkpoint(::Type{MCData{RNG}}, check_file::HDF5.Group) where {RNG}
    therm_sweeps = check_file["thermalization_sweeps"]
    sweeps = check_file["sweeps"]
    
    return MCData(
        rng = read_checkpoint(RNG, check_file["random_number_generator"]),
        sweeps = sweeps + therm_sweeps,
        measure = read_check
    )
    
    return nothing
end

function write!(data::MCData, mc::AbstractMC, file_prefix::AbstractString)
    checkpoint_write_time = @elapsed begin
        cp(file_prefix * ".meas.h5", file_prefix * ".meas.h5.tmp")
        h5open(file_prefix * ".meas.h5.tmp", "r+") do file
            write_measurements!(data, file)
        end

        h5open(fileprefix * ".dump.h5.tmp", "w") do file
            write_checkpoint(data, file)
            write_checkpoint(mc, file["simulation"])
        end
    end

    add_sample!(data.measure, "__ll_checkpoint_write_time", checkpoint_write_time)

    return nothing
end

function write_finalize(file_prefix::AbstractString)
    mv(file_prefix * ".dump.h5.tmp", file_prefix * ".dump.h5")
    mv(file_prefix * ".meas.h5.tmp", file_prefix * ".meas.h5")

    return nothing
end

function init_from_checkpoint(file_prefix::AbstractString, parameters::Dict)::Union{Nothing, Pair{MCData, MC}} where {MC <: AbstractMC}
    if !isfile(file_prefix * ".dump.h5")
        return nothing
    end

    checkpoint_read_time = @elapsed begin
        h5open(file_prefix * ".meas.h5.tmp", "r") do file
            data = read_checkpoint(MCData, file)
            
            mc = MC(parameters)
            read_checkpoint!(mc, file["simulation"])
        end
    end

    add_sample!(data.measure, "__ll_checkpoint_read_time", checkpoint_read_time)
    return (data, mc)
end
