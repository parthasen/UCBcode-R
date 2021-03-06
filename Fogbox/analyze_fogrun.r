# analyze_fogrun.r
require(qpcR)
###
  # helper functions
  na.sd <- function(x) return(sd(x, na.rm=TRUE))
  na.mean <- function(x) return(mean(x, na.rm=TRUE))
  get_species <- function(s){
    # return the species, assuming naming convention is species followed
    # by a numeric indicating the trial, e.g. blackoak1, blueoak3rep2, etc.
	n <- 1
	while(is.na(as.numeric(substr(s, n, n))))
	  n <- n + 1
	return(substr(s, 1, n - 1))
  }
  get_trial <- function(s){
  	n <- 1
	while(is.na(as.numeric(substr(s, n, n))))
	  n <- n + 1
	if(!is.na(as.numeric(substr(s, n, n + 1)))){
	  return(substr(s, n, n+1))
	}else{
	  return(substr(s, n, n))
	}
  }
  get_replicate <- function(s){
    n <- 1
	while(is.na(as.numeric(substr(s, n, n))))
	  n <- n + 1
	if(substr(s, n+1, n+3) == 'rep'){
	  return(substr(s, n+4, n+4))
	} else{
	  return('1')
	}
  }
  is_vertical <- function(s){
    n <- 1
	while(is.na(as.numeric(substr(s, n, n))))
	  n <- n + 1
	if(substr(s, n+1, n+4) == 'vert'){
	  return(TRUE)
	} else{
	  return(FALSE)
	}
  }
  get_area <- function(d, lt){
    # d is procdata
	# lt is the leaf area table
	leafid <- paste(d$species, d$trial, sep='') 
	# look up leaf area from table
	la <- lt[lt$trialname == leafid, 'area_cm2']
	# correct due to 1-in^2 scale is actually 0.9386 in^2 (dammit Ian)
	return(0.9386*la)
  }
  
  calc_with_uncertainty <- function(expr, d, proptype='stat'){
    # expr is an expression, e.g. expression(a - b)
	# d is a dataframe with columns corresponding to
	#   expression (e.g. names(d) = c('a', 'b')).
	#   first row contains means, second row contains sd
	r <- propagate(expr, d, type=proptype, do.sim=TRUE, nsim=10000, 
	               dist.sim='norm', plot=FALSE)$summary
	avg <- r$Prop[1]
	stdev <- r$Prop[2]
	return(data.frame(avg=avg, stdev=stdev))
  }
  stats_with_uncertainty <- function(d){
    # assumes d is a dataframe of measurements with two columns
    # first column is means, second column is standard deviations 
    widedat <- data.frame(dummy=c(NA, NA)) # need a dummy column for cbind
    d <- na.omit(d)
	nobs <- nrow(d)
    for(i in seq(nobs))
      widedat <- cbind(widedat, data.frame(m=c(d[[1]][i], d[[2]][i])))
	widedat['dummy'] <- NULL # remove the dummy column
	names(widedat) <- paste('m', seq(nobs), sep='')
	measnames <- names(widedat)
    widedat['nobs'] <- c(nobs, 0)
	expr <- parse(text=paste('(', paste(measnames, collapse='+'), ')/nobs'))   
    return(calc_with_uncertainty(expr, widedat))
  }
  calc_drift <- function(procdata){
    # format the data for uncertainty calculation
	# first row is mean, second is sd
	times <- seq(max(procdata$startbasevolt$timestamp), 
	             max(procdata$endbasevolt$timestamp), by=15)
	tsteps <- length(times)
	calcdat <- data.frame(endbasevolt=c(na.mean(procdata$endbasevolt$SEmV), 
	                                    na.sd(procdata$endbasevolt$SEmV)),
						  startbasevolt=c(na.mean(procdata$startbasevolt$SEmV), 
	                                      na.sd(procdata$startbasevolt$SEmV)),
						  runtime=c(tsteps*15, 0))
	equation <- expression((endbasevolt - startbasevolt)/runtime)
	# intermediate data
	intdat <- calc_with_uncertainty(equation, calcdat)
	# calculate the change in baseline voltage with uncertainty
	avg <- 15*seq(0, length(times)-1)*intdat$avg
	stdev <- rep(intdat$stdev, length(avg)) ## correct?
	return(data.frame(timestamp=times, avg=avg, stdev=stdev))
  }
  correct_drift <- function(d, drift){
    # find segment of drift that corresponds to timestamps in d
    sidx <- match(d$timestamp[1], drift$timestamp)
    eidx <- match(d$timestamp[nrow(d)], drift$timestamp)
	interval <- seq(sidx, eidx)
	corrected <- NULL
	expr <- expression(SEmV - driftmV)
	for(i in seq(along=interval)){
	  calcdat <- data.frame(SEmV=c(d$SEmV[i], 0), # In this case SEmV is an exact measurement
	                        driftmV=c(drift$avg[interval[i]], drift$stdev[interval[i]]))
	  corrected <- rbind(corrected, calc_with_uncertainty(expr, calcdat))
	}
	d['CSEmV'] <- corrected$avg
	d['CSEmV.sd'] <- corrected$stdev
    return(d)
  }
  summarize_basevolt <- function(startvolt, endvolt){
    # combine the start and end baseline voltages to calculate
    # the error (variability) in measurements
    # we used separate averages for start and end baseline voltage
    # to calculate the drift. But now we combine all those baseline
    # measurements to understand the overall variation (error) in 
    # load cell readings
    list(avg=na.mean(c(startvolt$CSEmV, endvolt$CSEmV)),
         stdev=na.sd(c(startvolt$CSEmV, endvolt$CSEmV)))
  }  
  strip_basevoltage <- function(d, basevoltstats){
    # adds a column representing the load cell measurement stripped of
    # the offset voltage when the cradle is attached (the 'baseline' or
    # 'background' voltage)
	expr <- expression(CSEmV - basevolt)
	stripped <- NULL
	for(i in seq(along=d$CSEmV)){
	  calcdat <- data.frame(CSEmV=c(d$CSEmV[i], d$CSEmV.sd[i]),
	                        basevolt=c(basevoltstats$avg, basevoltstats$stdev))
	  stripped <- rbind(stripped, calc_with_uncertainty(expr, calcdat))
	}
    d['loadmV'] <- stripped$avg
    d['loadmV.sd'] <- stripped$stdev
    return(d)
  }  
  calc_conversionfactor <- function(calibdat, refmass){
    expr <- expression(refmass/calibdat)
	# loadmV.sd is constant
	cdstats <- stats_with_uncertainty(calibdat[c('loadmV', 'loadmV.sd')])
	calcdat <- data.frame(refmass=c(refmass$avg, refmass$stdev),
	                      calibdat=c(cdstats$avg, cdstats$stdev))
	return(calc_with_uncertainty(expr, calcdat))
  }
  calc_watermass <- function(wetdat, drydat, convdat){
    # wetdat is e.g. procdat$wetragvolt
    # drydat would then be procdat$dryragvolt
    # convdat is data for the conversion factor
	expr <- expression((wetmass - drymass)*cf)
	wrstats <- stats_with_uncertainty(wetdat[c('loadmV', 'loadmV.sd')])
	drstats <- stats_with_uncertainty(drydat[c('loadmV', 'loadmV.sd')])
	calcdat <- data.frame(wetmass=c(wrstats$avg, wrstats$stdev),
	                      drymass=c(drstats$avg, drstats$stdev),
						  cf=c(convdat$avg, convdat$stdev))
    return(calc_with_uncertainty(expr, calcdat))
  }
  calc_dryleafmass <- function(d, convdat){
    # d is the dry leaf readings
	dlstats <- stats_with_uncertainty(d[c('loadmV', 'loadmV.sd')])
	expr <- expression(leafvolt*cf)
	calcdat <- data.frame(leafvolt=c(dlstats$avg, dlstats$stdev), 
	                       cf=c(convdat$avg, convdat$stdev))
	return(calc_with_uncertainty(expr, calcdat))
  }
  calc_leafwatermass <- function(leafdat, dlstats, convdat){
    # leafdat is leaf of variable wetness, i.e. rundata
	# dlstats is the dry leaf stats via stats_with_uncertainty()
	expr <- expression(wetleaf*cf - dryleaf)
    m <- NULL			  
	for(i in seq(along=leafdat$loadmV)){
	  calcdat <- data.frame(wetleaf=c(leafdat$loadmV[i], leafdat$loadmV.sd[i]),
							dryleaf=c(dlstats$avg, dlstats$stdev),
                            cf=c(convdat$avg, convdat$stdev))
	  m <- rbind(m, calc_with_uncertainty(expr, calcdat))
	}
	leafdat['watermass'] <- m$avg
	leafdat['watermass.sd'] <- m$stdev
	return(leafdat)
  }
  calc_surfacedensity <- function(leafdat, leafarea){
    expr <- expression(watermass/leafarea)
	m <- NULL
	for(i in seq(along=leafdat$watermass)){
	calcdat <- data.frame(leafarea=c(leafarea, 0), 
	                      watermass=c(leafdat$watermass[i], 
						              leafdat$watermass.sd[i]))
	m <- rbind(m, calc_with_uncertainty(expr, calcdat))
	}
	leafdat[['surfacedensity']] <- m$avg
	leafdat[['surfacedensity.sd']] <- m$stdev
	return(leafdat)
  }
###
#
analyze_fogrun <- function(procdata, leaftable, calibrationstandard=data.frame(avg=5.33, stdev=0)){
# procdata is a list of objects produced by process_fogrun
# calibrationstandard = the mean and standard error of the
#   reference mass used for calibrating load cell
#
  # get species
  procdata[['species']] <- get_species(procdata$name)
  procdata[['trial']] <- get_trial(procdata$name)
   # get leaf area
  procdata[['leafarea']] <- get_area(procdata, leaftable)  
  procdata[['replicate']] <- get_replicate(procdata$name)
  procdata[['isvertical']] <- is_vertical(procdata$name)
  # calculate the drift
  measdrift <- calc_drift(procdata)
  procdata[['max_drift']] <- max(measdrift$avg)
  # correct procdata for drift
  # assumes startbasevolt is the earliest set of measurements
  # and endbasevolt is the latest set of measurements
  for(label in c('startcalibvolt', 'dryragvolt', 'wetragvolt', 
                 'dryleafvolt', 'rundata', 'endbasevolt'))
    procdata[[label]] <- correct_drift(procdata[[label]], measdrift)
  # also add dummy columns to startbasevolt
  procdata$startbasevolt['CSEmV'] <- procdata$startbasevolt$SEmV
  procdata$startbasevolt['CSEmV.sd'] <- 0
  # get baseline voltage
  bvstats <- summarize_basevolt(procdata$startbasevolt, procdata$endbasevolt)
  # strip baseline voltage from everything
  for(label in c('startcalibvolt', 'dryragvolt', 'wetragvolt', 'rundata', 
                 'dryleafvolt', 'startbasevolt', 'endbasevolt'))
    procdata[[label]] <- strip_basevoltage(procdata[[label]], bvstats)
  # get conversion factor from calibration data
  procdata[['conversionfactor']] <- calc_conversionfactor(procdata$startcalibvolt, 
                                                          calibrationstandard)
  # calculate LWS water mass
  procdata[['LWSwatermass']] <- calc_watermass(procdata$wetragvolt, 
                                             procdata$dryragvolt, 
											 procdata$conversionfactor)
  # calculate leaf water mass for rundata
  procdata[['dryleafmass']] <- calc_dryleafmass(procdata$dryleafvolt,
											    procdata$conversionfactor)
  procdata[['rundata']] <- calc_leafwatermass(procdata$rundata, 
                                              procdata$dryleafmass,
											  procdata$conversionfactor)
  # normalize leaf mass by leaf area
  procdata[['rundata']] <- calc_surfacedensity(procdata$rundata, 
                                               procdata$leafarea)
  return(procdata)
}
