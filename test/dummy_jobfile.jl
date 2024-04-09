using Carlo
using Carlo.JobTools
include("test_mc.jl")

tm = TaskMaker()
tm.thermalization = 100000
tm.sweeps = 100000000000
tm.binsize = 100

tm.rebin_sample_skip = 1000
tm.rebin_length = 1000

task(tm)

job = JobInfo(
    ARGS[1] * "/test",
    TestMC;
    tasks = make_tasks(tm),
    checkpoint_time = "00:05",
    run_time = "00:10",
)

Carlo.start(job, ARGS[2:end])
