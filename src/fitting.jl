@inline scaletoLUT(par, parmin, sz, width) = (par-parmin)*(sz-1)/width + 1

"""
    surrogate_sprdata_error(optpars, surrogate)

This function takes a set of parameters and interpolates a simulated kinetics
curve from the Look Up Table that we made in Tutorial 1, and then calculates the
error between the interpolated curve and the experimental data using a sum of
squares.

Arguments:
`optpars` -  
"""
function surrogate_sprdata_error(optpars, surrogate::Surrogate, aligned_data::AlignedData)
    surranges = surrogate.param_ranges
    sursize   = surrogate.surrogate_size
    
    @unpack times, refdata_nonan, antibodyconcens = aligned_data
    
    # width of each range of parameters in the surrogate
    dq1 = surranges.logkon_range[2] - surranges.logkon_range[1]        
    dq2 = surranges.logkoff_range[2] - surranges.logkoff_range[1]        
    dq3 = surranges.logkonb_range[2] - surranges.logkonb_range[1]        
    dq4 = surranges.reach_range[2] - surranges.reach_range[1]        

    # the interpolant assumes a function y = f(x), where we provided y, and x is
    # just an integer for each data point we must therefore rescale from the
    # actual x-value in log parameter space to the integer space used in the
    # interpolant:
    q2 = scaletoLUT(optpars[2], surranges.logkoff_range[1], sursize[2], dq2)
    q3 = scaletoLUT(optpars[3], surranges.logkonb_range[1], sursize[3], dq3)
    q4 = scaletoLUT(optpars[4], surranges.reach_range[1], sursize[4], dq4)

    e1     = zeros(length(times),length(antibodyconcens))    
    refabc = antibodyconcens[1]
    for (j,abc) in enumerate(antibodyconcens)

        # rescale the on rate to account for changing concentraions of antibody
        logkon = optpars[1] + log10(abc / refabc) 
        q1     = scaletoLUT(logkon, surranges.logkon_range[1], sursize[1], dq1)
        
        for (i,t) in enumerate(times)
            if !isnan(t) 
                e1[i,j] = 10.0^(optpars[5]) * surrogate.itp(q1,q2,q3,q4,t) 
            end  
        end
    end
   
    # calculate the ℓ₂ error 
    return sqrt(value(L2DistLoss(), vec(e1), vec(refdata_nonan), AggMode.Sum()))
end


function fit_spr_data(surrogate::Surrogate, aligneddat::AlignedData, searchrange; 
                      NumDimensions=5, 
                      Method=:xnes, 
                      MaxSteps=5000, 
                      TraceMode=:compact, 
                      TraceInterval=10.0, 
                      kwargs...)

    # use a closure as bboptimize takes functions of a parameter vector only
    bboptfun = optpars -> surrogate_sprdata_error(optpars, surrogate, aligneddat)

    # optimize for the best fitting parameters
    bboptimize(bboptfun; SearchRange=searchrange, NumDimensions, Method, MaxSteps, 
                         TraceMode, TraceInterval, kwargs...) #,Tracer=:silent)
end

# note this requires concentrations to be per volume!!!
function bboptpars_to_physpars(bboptpars, antibodyconcen, antigenconcen, 
                               surrogate_antigenconcen)
    kon   = (10.0 ^ bboptpars[1]) / antibodyconcen  # make bimolecular
    koff  = (10.0 ^ bboptpars[2])
    konb  = (10.0 ^ bboptpars[3])
    reach = bboptpars[4] * cbrt(surrogate_antigenconcen/antigenconcen)
    CP    = (10.0 ^ bboptpars[5])        
    [kon,koff,konb,reach,CP]
end


"""
Generate the biophysical parameters and run a forward simulation given
parameters from the optimizer.

Arguments:
logpars   = vector of the five optimization parameters:
            [logkon,logkoff,logkonb,reach,logCP]
simpars   = Simparams instance
outputter = an OutPutter instance for what simulation data to record
"""
function update_pars_and_run_spr_sim!(outputter, logpars, simpars::SimParams)    
    # get antigen concentration for use in simulations
    # and convert to μM
    antigenconcen = inv_cubic_nm_to_muM(getantigenconcen(simpars))
    
    # we already account for the antibody concentration in kon, so set it to 1.0
    biopars = biopars_from_fitting_vec(logpars; antigenconcen, antibodyconcen=1.0)

    # reset the outputter
    outputter()

    # run the simulations
    run_spr_sim!(outputter, biopars, simpars)

    nothing
end

# plots data and simulated curves and saves it in filename
# returns figure
function visualisefit(bbopt_output, aligneddat::AlignedData, simpars::SimParams, 
                      filename=nothing)
    @unpack times,refdata,antibodyconcens = aligneddat
    @unpack tstop,dt = simpars
    params = copy(bbopt_output.method_output.population[1].params)

    # plot aligned experimental data
    fig1 = plot(xlabel="time", ylabel="RU")
    for sprcurve in eachcol(refdata)
        plot!(fig1, times, sprcurve, label="", color="black")
    end

    # plot simulation data with fit parameters
    timepoints = collect(range(0.0, tstop, step=dt))
    ps         = copy(params)
    abcref     = antibodyconcens[1]
    for abc in antibodyconcens
        # set kon
        ps[1] = params[1] + log10(abc/abcref)

        outputter = TotalBoundOutputter(length(timepoints))
        update_pars_and_run_spr_sim!(outputter, ps, simpars)
        plot!(fig1, timepoints, outputter.bindcnt, label="")
    end

    (filename !== nothing) && savefig(fig1, filename)

    fig1
end


# saves data and simulated data in files with basename outfile
function savefit(bbopt_output, aligneddat::AlignedData, simpars::SimParams, outfile)
    @unpack times, refdata, antibodyconcens, antigenconcen = aligneddat
    @unpack tstop, dt = simpars

    params = copy(bbopt_output.method_output.population[1].params)

    timepoints     = collect(range(0.0, tstop, step=dt))
    savedata       = zeros(length(timepoints), 2*length(antibodyconcens)+1)
    savedata[:,1] .= timepoints
    
    abcref = antibodyconcens[1]
    ps     = copy(params)
    for (j,abc) in enumerate(antibodyconcens)
        
        # This following is really hacky and needs to be replaced...        
        # Assign and save the aligned data to match timepoints
        nstart = Int(times[1])        
        savedata[1:nstart,2*j] .= NaN       
        for n=1:length(times) 
            savedata[nstart+n,2*j] = refdata[n,j] 
        end

        # Simulate the model and save the averaged kinetics data
        ps[1] = params[1] + log10(abc/abcref)
        outputter = TotalBoundOutputter(length(timepoints))
        update_pars_and_run_spr_sim!(outputter, ps, simpars) 
        savedata[:,2*j+1] .= outputter.bindcnt
    end

    # headers for writing the simulation curves
    EH = ["Experimental Data $(antibodyconcens[j]) nM" for j in 1:length(antibodyconcens)]
    MH = ["Model Data $(antibodyconcens[j]) nM" for j in 1:length(antibodyconcens)]
    CH = [Z[i] for i=1:length(antibodyconcens) for Z in [EH,MH]]
    headers = ["times"]
    for h in CH
        push!(headers,h)
    end    

    # get parameter fits
    bs = best_candidate(bbopt_output)
    bf = best_fitness(bbopt_output)

    # Write the fits to a spreadsheet
    fname = outfile * "_fit.xlsx"
    XLSX.openxlsx(fname, mode="w") do xf
        # SPR and fit curves
        sheet = xf[1]
        sheet[1,1:length(headers)] = headers
        nrows,ncols = size(savedata)
        for j in 1:ncols
            sheet[2:(nrows+1),j] = savedata[:,j]
        end

        nextcol = ncols + 2
        nextrow = 1

        # internal parameters
        logparnames = ["Best fit parameters (internal):","logkon","logkoff","logkonb","reach","logCP"]
        cols = nextcol:(nextcol+length(logparnames)-1)
        sheet[nextrow,cols] = logparnames
        sheet[nextrow+1,cols] = ["",bs...]

        # biophysical parameters
        parnames = ["Best fit parameters (physical):","kon","koff","konb","reach","CP"]
        sheet[nextrow+3,cols] = parnames

        # convert internal simulator concentration from (nm)⁻³ to μM
        simagc = inv_cubic_nm_to_muM(getantigenconcen(simpars))
        pars   = bboptpars_to_physpars(bs, antibodyconcens[1], antigenconcen, simagc)
        sheet[nextrow+4,cols] = ["",pars...]        
    end

    ##### save parameters
    open(outfile*"_Fitted.txt", "w+") do file
        println(file, last(splitpath(outfile)), "\n")
        println(file, "Best candidate found (kon, koff, konb, reach, CP): ", bs)
        println(file, "Fitness: ", bf)
    end

    nothing
end

