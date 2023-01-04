using Dates
using Logging

abstract type AbstractRunner end

const DefaultRNG = Random.Xoshiro

mutable struct SingleRunner{MC<:AbstractMC} <: AbstractRunner
    job::JobInfo
    walker::Union{Walker{MC,DefaultRNG},Nothing}

    time_start::Dates.DateTime
    time_last_checkpoint::Dates.DateTime

    task_id::Union{Int32,Nothing}
    tasks::Vector{RunnerTask}

    function SingleRunner(job::JobInfo, ::Type{MC}) where {MC<:AbstractMC}
        return new{MC}(job, nothing, Dates.now(), Dates.now(), 1, RunnerTask[])
    end
end

function start!(runner::SingleRunner{MC}) where {MC<:AbstractMC}
    runner.time_start = Dates.now()
    runner.time_last_checkpoint = runner.time_start

    runner.tasks = read_progress(runner.job)
    runner.task_id = get_new_task_id(runner.tasks, runner.task_id)

    while runner.task_id !== nothing && !is_end_time(runner.job, runner.time_start)
        task = runner.job.tasks[runner.task_id]
        runner_task = runner.tasks[runner.task_id]
        walkerdir = walker_dir(runner_task, 1)

        runner.walker = read_checkpoint(Walker{MC,DefaultRNG}, walkerdir, task.params)
        if runner.walker !== nothing
            @info "read $walkerdir"
        else
            runner.walker = Walker{MC,DefaultRNG}(task.params)
            @info "initialized $walkerdir"
        end

        while !is_done(runner_task) && !time_is_up(runner)
            runner_task.sweeps += step!(runner.walker)

            if is_checkpoint_time(runner.job, runner.time_last_checkpoint)
                write_checkpoint(runner)
            end
        end

        write_checkpoint(runner)

        taskdir = runner_task.dir
        write_output(runner.walker.impl, taskdir)
        @info "merging $(taskdir)"
        merge_results(MC, runner_task)

        runner.task_id = get_new_task_id(runner.tasks, runner.task_id)
    end

    concatenate_results(runner.job)
    @info "Job complete."

    return nothing
end

function get_new_task_id(
    tasks::AbstractVector{RunnerTask},
    old_id::Integer,
)::Union{Integer,Nothing}
    next_unshifted = findfirst(x -> !is_done(x), circshift(tasks, -old_id))
    if next_unshifted === nothing
        return nothing
    end

    return (next_unshifted + old_id - 1) % length(tasks) + 1
end

get_new_task_id(::AbstractVector{RunnerTask}, ::Nothing) = nothing

function write_checkpoint(runner::SingleRunner)
    runner.time_last_checkpoint = Dates.now()
    walkerdir = walker_dir(runner.tasks[runner.task_id], 1)
    write_checkpoint!(runner.walker, walkerdir)
    write_checkpoint_finalize(walkerdir)
    @info "checkpointing $walkerdir"

    return nothing
end