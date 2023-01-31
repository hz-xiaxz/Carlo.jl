using LoadLeveller
using Formatting
using Random
using Statistics

function create_mock_data(
    generator;
    walkers::Integer,
    internal_binsize::Integer,
    samples_per_walker::Integer,
    extra_samples::Integer = 0,
    obsname::Symbol,
)::Tuple{Vector{String},Vector{Float64}}
    tmpdir = mktempdir()
    samples = zeros(0)

    filenames = map(x -> format("{}/walker{}.h5", tmpdir, x), 1:walkers)

    idx = 1
    for walker = 1:walkers
        nsamples = samples_per_walker + extra_samples * (walker == 1)
        start_sample = length(samples)+1
        h5open(filenames[walker], "w") do file
            meas = LoadLeveller.Measurements{Float64}(internal_binsize)
            for i = 1:nsamples
                value = generator(idx)
                LoadLeveller.add_sample!(meas, obsname, value)
                if i <= (nsamples ÷ internal_binsize) * internal_binsize
                    append!(samples, value)
                end
                idx += 1
            end
            LoadLeveller.write_measurements!(meas, create_group(file, "observables"))
        end
        h5open(filenames[walker], "r") do file
            @test read(file, "observables/$obsname/samples") == mean(reshape(copy(samples[start_sample:end]), internal_binsize, :); dims=1)
        end
    end

    return collect(filenames), samples
end

@testset "Merge counter" begin
    tmpdir = mktempdir()
    walkers = 4

    for internal_binsize in [1, 3, 4]
        for samples_per_walker in [5, 7]
            extra_samples = 100
            total_samples = walkers * samples_per_walker + extra_samples

            @testset "samples = $(total_samples), binsize = $(internal_binsize)" begin
                filenames, samples = create_mock_data(;
                    walkers = walkers,
                    obsname = :count_test,
                    internal_binsize = internal_binsize,
                    samples_per_walker = samples_per_walker,
                    extra_samples = extra_samples,
                ) do idx
                    return idx
                end

                for rebin_length in [nothing, 1, 2]
                    @testset "rebin_length = $(rebin_length)" begin
                        results = LoadLeveller.merge_results(
                            filenames,
                            data_type = Float64,
                            rebin_length = rebin_length,
                        )
                        count_obs = results[:count_test]

                        rebinned_samples = samples[1:internal_binsize*count_obs.rebin_length*count_obs.rebin_count]

                        @test count_obs.total_sample_count == length(samples) ÷ internal_binsize
                        @test count_obs.mean[1] ≈ mean(rebinned_samples)
                        if rebin_length !== nothing
                            @test count_obs.rebin_length == rebin_length
                        else
                            @test 1 <
                                  count_obs.rebin_length * count_obs.rebin_count <=
                                  count_obs.total_sample_count
                        end
                    end
                end
            end
        end
    end
end

@testset "Merge AR(1)" begin
    walkers = 2

    # parameters for an AR(1) random walk y_{t+1} = α y_{t} + N(μ=0, σ)
    # autocorrelation time and error of this are known analytically
    for ar1_alpha in [0.5,0.7,0.8,0.9]
        @testset "α = $ar1_alpha" begin
            ar1_sigma = 0.54

            ar1_y = 0
            rng = Xoshiro()

            filenames, _ =create_mock_data(;
                walkers = walkers,
                obsname = :ar1_test,
                samples_per_walker = 200000,
                internal_binsize = 1,
            ) do idx
                ar1_y = ar1_alpha * ar1_y + ar1_sigma * randn(rng)
                return ar1_y
            end

            results = LoadLeveller.merge_results(
                filenames,
                data_type = Float64,
                rebin_length = 100
            )

            # AR(1)
            ar1_obs = results[:ar1_test]

            expected_mean = 0.0
            expected_std = ar1_sigma / sqrt(1 - ar1_alpha^2)
            expected_autocorrtime = -1 / log(ar1_alpha)
            expected_autocorrtime = 0.5*(1+2*ar1_alpha/(1-ar1_alpha))
            println("$(ar1_obs.rebin_count), $(ar1_obs.rebin_length)")

            @test abs(ar1_obs.mean[1] - expected_mean) < 4 * ar1_obs.error[1]
            @test isapprox(ar1_obs.autocorrelation_time[1], expected_autocorrtime, rtol = 0.1)
        end
    end
end
