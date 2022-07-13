@inline scaletoLUT(par, parmin, sz, width) = (par-parmin)*(sz-1)/width + 1

"""
    surrogate_sprdata_error(optpars, surrogate::Surrogate, aligned_data::AlignedData)

This function takes a set of optimization parameters and interpolates a
simulated kinetics curve from the surrogate, returning the ``L^2`` error against
the provided data.

"""
function surrogate_sprdata_error(optpars, surrogate::Surrogate, aligned_data::AlignedData)
    surpars = surrogate.surpars
    sursize = surrogate.surrogate_size

    @unpack times, refdata, antibodyconcens = aligned_data

    # width of each range of parameters in the surrogate
    dq1 = surpars.logkon_range[2] - surpars.logkon_range[1]
    dq2 = surpars.logkoff_range[2] - surpars.logkoff_range[1]
    dq3 = surpars.logkonb_range[2] - surpars.logkonb_range[1]
    dq4 = surpars.reach_range[2] - surpars.reach_range[1]

    # the interpolant assumes a function y = f(x), where we provided y, and x is
    # just an integer for each data point we must therefore rescale from the
    # actual x-value in log parameter space to the integer space used in the
    # interpolant:
    q2 = scaletoLUT(optpars[2], surpars.logkoff_range[1], sursize[2], dq2)
    q3 = scaletoLUT(optpars[3], surpars.logkonb_range[1], sursize[3], dq3)
    q4 = scaletoLUT(optpars[4], surpars.reach_range[1], sursize[4], dq4)

    err = 0.0
    refabc = antibodyconcens[1]
    for (j,abc) in enumerate(antibodyconcens)

        # rescale the on rate to account for changing concentrations of antibody
        logkon = optpars[1] + log10(abc / refabc)
        q1 = scaletoLUT(logkon, surpars.logkon_range[1], sursize[1], dq1)

        sprdata = refdata[j]
        for (i,t) in enumerate(times[j])
            # should below be t + 1.0 to scale [0.0,T] to [1,T+1]?
            newerr = 10.0^(optpars[5]) * surrogate.itp(q1,q2,q3,q4,t+1) - sprdata[i]
            err += newerr * newerr
        end
    end

    # calculate the ℓ₂ error
    return sqrt(err)
end

checkrange(rsur,ropt) = (rsur[1] <= ropt[1] <= ropt[2] <= rsur[2])

function checkranges(optranges, sr::SurrogateParams)
    checkrange(sr.logkon_range, optranges[1]) || error("Optimizer logkon_range not a subset of surrogate logkon_optrange")
    checkrange(sr.logkoff_range, optranges[2]) || error("Optimizer logkoff_range not subset of surrogate logkoff_optrange")
    checkrange(sr.logkonb_range, optranges[3]) || error("Optimizer logkonb_range not subset of surrogate logkonb_optrange")
    checkrange(sr.reach_range, optranges[4]) || error("Optimizer reach_range not subset of surrogate reach_optrange")
    nothing
end

"""
    fit_spr_data(surrogate::Surrogate, aligneddat::AlignedData, searchrange;
                        NumDimensions=5,
                        Method=:xnes,
                        MaxSteps=5000,
                        TraceMode=:compact,
                        TraceInterval=10.0,
                        kwargs...)

Find best fit parameters of the surrogate to the given data.

Notes:
- `searchrange` should be a BlackBoxOptim compatible vector of `Tuple`s of the
  form:
  ```
    searchrange = [logkon_optrange,logkoff_optrange,logkonb_optrange,reach_optrange,logCP_optrange]
  ```
  or
  ```
    searchrange = [logCP_optrange]
  ```
  In the latter case the other parameter ranges are set equal to the range
  within the surrogate.
- Uses `xnes` from BlackBoxOptim by default.
- kwargs are passed through to the optimizer.
- Returns the best fit optimization object and the best fit (bio) parameters as a tuple.
"""
function fit_spr_data(surrogate::Surrogate, aligneddat::AlignedData, searchrange;
                      NumDimensions=5,
                      Method=:xnes,
                      MaxSteps=5000,
                      TraceMode=:compact,
                      TraceInterval=10.0,
                      kwargs...)


    if length(searchrange) == 1
        sp = surrogate.surpars
        sr = [sp.logkon_range, sp.logkoff_range, sp.logkonb_range, sp.reach_range, searchrange[1]]
    else
        sr = searchrange
    end
    checkranges(sr, surrogate.surpars)

    # use a closure as bboptimize takes functions of a parameter vector only
    bboptfun = optpars -> surrogate_sprdata_error(optpars, surrogate, aligneddat)

    # optimize for the best fitting parameters
    bboptres = bboptimize(bboptfun; SearchRange=sr, NumDimensions, Method, MaxSteps,
                          TraceMode, TraceInterval, kwargs...) #,Tracer=:silent)

    # calculate the bestfit biological parameters
    bestpars = bboptpars_to_physpars(best_candidate(bboptres), aligneddat, surrogate)

    bboptres, bestpars
end

"""
    bboptpars_to_physpars(bboptpars, antibodyconcen, antigenconcen,
                                surrogate_antigenconcen)

    bboptpars_to_physpars(bboptpars, aligned_data::AlignedData, surrogate::Surrogate)

Converts parameters vector from BlackBoxOptim to physical parameters, converting
the reach from simulation to physical values.

Notes:
- The reach is converted from the internal parameter value, εᵢ, to the physical
  value, εₑ, via
  ```math
    \\varepsilon_e = \\varepsilon_i \\left(\\frac{[AGC]_i}{[AGC]_e}\\right)^{\\tfrac{1}{3}},
  ```
  where ``[AGC]_i`` is the internal simulator's antigen concentration and
  ``[AGC]_e`` is the concentration used in experiments.
- Assumes these two concentrations have consistent units.
"""
function bboptpars_to_physpars(bboptpars, antibodyconcen, antigenconcen,
                               surrogate_antigenconcen)
    kon   = (10.0 ^ bboptpars[1]) / antibodyconcen  # make bimolecular
    koff  = (10.0 ^ bboptpars[2])
    konb  = (10.0 ^ bboptpars[3])
    reach = bboptpars[4] * cbrt(surrogate_antigenconcen/antigenconcen)
    CP    = (10.0 ^ bboptpars[5])
    [kon,koff,konb,reach,CP]
end

function bboptpars_to_physpars(bboptpars, ad::AlignedData, sur::Surrogate)
    bboptpars_to_physpars(bboptpars, ad.antibodyconcens[1], ad.antigenconcen,
                          sur.surpars.antigenconcen)
end


"""
    update_pars_and_run_spr_sim!(outputter, logpars, simpars::SimParams)

Generate the biophysical parameters and run a forward simulation given
parameters from the optimizer.

Arguments:
- outputter = an OutPutter instance for what simulation data to record
- logpars   = vector of the five optimization parameters:
              [logkon,logkoff,logkonb,reach,logCP]
- simpars   = [`SimParams`](@ref) instance, should be consistent with the
              surrogate
"""
function update_pars_and_run_spr_sim!(outputter, logpars, simpars::SimParams)
    # get antigen concentration used in simulations and convert to μM
    antigenconcen = inv_cubic_nm_to_muM(getantigenconcen(simpars))

    # we already account for the antibody concentration in kon, so set it to 1.0
    biopars = biopars_from_fitting_vec(logpars; antigenconcen, antibodyconcen=1.0)

    # reset the outputter
    outputter()

    # run the simulations
    run_spr_sim!(outputter, biopars, simpars)

    nothing
end

"""
    visualisefit(bbopt_output, aligneddat::AlignedData, simpars::SimParams,
                 surrogate::Surrogate, filename=nothing)

Plots fit between data and simulated curves using fitted parameters across a set
of antibody concentrations.

Notes:
- `filename = nothing` if set will cause the graph to be saved.
"""
function visualisefit(bbopt_output, aligneddat::AlignedData, surrogate::Surrogate,
                      simpars::SimParams, filename=nothing)
    @unpack times,refdata,antibodyconcens = aligneddat
    params = copy(bbopt_output.method_output.population[1].params)

    # plot aligned experimental data
    fig1 = plot(; xlabel="time", ylabel="RU", legend=false)
    for (i,sprcurve) in enumerate(refdata)
        plot!(fig1, times[i], sprcurve, color="black")
    end

    # plot simulation data with fit parameters
    ps = copy(params)
    abcref = antibodyconcens[1]
    for (i,abc) in enumerate(antibodyconcens)
        # set kon
        ps[1] = params[1] + log10(abc/abcref)

        # save at the SPR data times
        outputter = TotalBoundOutputter(length(times[i]))
        simpars.tsave = times[i]
        simpars.tstop = last(times[i])

        update_pars_and_run_spr_sim!(outputter, ps, simpars)
        plot!(fig1, times[i], means(outputter))
    end

    (filename !== nothing) && savefig(fig1, filename)

    fig1
end


"""
    savefit(bbopt_output, aligneddat::AlignedData, surrogate::Surrogate, simpars::SimParams,
            outfile)

Saves the data, simulated data with fit parameters, and fit parameters in an
XLSX spreadsheet with the given name.
"""
function savefit(bbopt_output, aligneddat::AlignedData, surrogate::Surrogate,
                 simpars::SimParams, outfile)
    @unpack times, refdata, antibodyconcens, antigenconcen = aligneddat

    savedata = Vector{Vector{Float64}}(undef, 3*length(antibodyconcens))

    params = copy(bbopt_output.method_output.population[1].params)
    abcref = antibodyconcens[1]
    ps     = copy(params)
    for (j,abc) in enumerate(antibodyconcens)
        idx = 3*(j-1) + 1

        savedata[idx] = times[j]
        savedata[idx+1] = refdata[j]

        # times to save model simulations at are same as the SPR data
        outputter = TotalBoundOutputter(length(times[j]))
        simpars.tsave = times[j]
        simpars.tstop = last(times[j])

        # Simulate the model and save the averaged kinetics data
        ps[1] = params[1] + log10(abc/abcref)
        update_pars_and_run_spr_sim!(outputter, ps, simpars)
        savedata[idx+2] = means(outputter)
    end

    # headers for writing the simulation curves
    EH = ["Experimental Data $(antibodyconcens[j]) nM" for j in 1:length(antibodyconcens)]
    MH = ["Model Data $(antibodyconcens[j]) nM" for j in 1:length(antibodyconcens)]
    headers = Vector{String}()
    for i in eachindex(antibodyconcens)
        push!(headers, "times")
        push!(headers, EH[i])
        push!(headers, MH[i])
    end

    # get parameter fits
    bs = best_candidate(bbopt_output)
    bf = best_fitness(bbopt_output)

    # Write the fits to a spreadsheet
    fname = outfile * "_fit.xlsx"
    XLSX.openxlsx(fname, mode="w") do xf
        # SPR and fit curves
        sheet = xf[1]
        XLSX.rename!(sheet, "SPR and Fit Curves")
        sheet[1,1:length(headers)] = headers
        for (j,sd) in enumerate(savedata)
            nrows = length(sd)
            sheet[2:(nrows+1),j] = sd
        end

        # make separate sheet for fit parameter values
        XLSX.addsheet!(xf, "Fit Parameters")
        sheet = xf[2]

        # internal parameters
        logparnames = ["Best fit parameters (internal):","logkon","logkoff","logkonb","reach","logCP"]
        rows = 1:length(logparnames)
        sheet[rows,1] = logparnames
        sheet[rows,2] = ["",bs...]

        # biophysical parameters
        parnames = ["Best fit parameters (physical):","kon","koff","konb","reach","CP"]
        sheet[rows,4] = parnames

        # convert internal simulator concentration from (nm)⁻³ to μM as a consistency check
        simagc = inv_cubic_nm_to_muM(getantigenconcen(simpars))
        @assert isapprox(simagc, surrogate.surpars.antigenconcen, atol=1e-12)

        pars = bboptpars_to_physpars(bs, aligneddat, surrogate)
        sheet[rows,5] = ["",pars...]

        # fitness
        row = last(rows) + 2
        sheet[row,1] = "Fitness"
        sheet[row,2] = bf
    end

    nothing
end
