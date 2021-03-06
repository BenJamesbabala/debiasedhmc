
# This file consists of the general-purpose functions coupled_chains, continue_coupled_chains,
# and H_bar, which implement our debiased MCMC algorithm for general kernels and functions h(.)

# from coupled_chains -----------------------------------------------------
# Run coupled chains until max(tau, K) where tau is the meeting time and K specified by user
#'@rdname coupled_chains
#'@title Coupled MCMC chains
#'@description Sample two MCMC chains, each following \code{single_kernel} marginally,
#' and \code{coupled_kernel} jointly, until min(max(tau, K), max_iterations), where tau
#' is the first time at which the two chains meet (i.e. take the same value exactly).
#' Or more precisely, they meet with a delay of one, i.e. X_t = Y_{t-1}. The chains
#' are initialized from the distribution provided in \code{rinit}.
#'
#'  See \code{\link{get_hmc_kernel}}
#' for an example of function returning the appropriate kernels.
#'
#'@param single_kernel function taking a state (in a vector) and an iteration, and returning
#' a list with a key named \code{chain_state} and containing the next state.
#'@param coupled_kernel function taking two states (in two vectors) and an iteration,
#'and returning a list with keys \code{chain_state1} and \code{chain_state2}.
#'@param rinit function taking no arguments are returning an initial state for a Markov chain.
#'@param K number of iterations desired (will be proportional to the computing cost if meeting occurs before \code{K},
#' default to 1).
#'@param max_iterations number of iterations at which the function stops if it is still running  (default to Inf).
#'@param preallocate  expected number of iterations, used to pre-allocate memory (default to 10).
#'@export
coupled_chains <- function(single_kernel, coupled_kernel, rinit, K = 1, max_iterations = Inf, preallocate = 10){
  chain_state1 <- rinit()
  chain_state2 <- rinit()
  p <- length(chain_state1)
  samples1 <- matrix(nrow = K+preallocate+1, ncol = p)
  samples2 <- matrix(nrow = K+preallocate, ncol = p)
  samples1[1,] <- chain_state1
  samples2[1,] <- chain_state2
  current_nsamples1 <- 1
  iter <- 1
  chain_state1 <- single_kernel(chain_state1, iter)$chain_state
  current_nsamples1 <- current_nsamples1 + 1
  samples1[current_nsamples1,] <- chain_state1
  meet <- FALSE
  finished <- FALSE
  meetingtime <- Inf
  while (!finished && iter < max_iterations){
    iter <- iter + 1
    if (meet){
      chain_state1 <- single_kernel(chain_state1, iter)$chain_state
      chain_state2 <- chain_state1
    } else {
      res_coupled_kernel <- coupled_kernel(chain_state1, chain_state2, iter)
      chain_state1 <- res_coupled_kernel$chain_state1
      chain_state2 <- res_coupled_kernel$chain_state2
      if (all(chain_state1 == chain_state2) && !meet){
        # recording meeting time tau
        meet <- TRUE
        meetingtime <- iter
      }
    }
    if ((current_nsamples1+1) > nrow(samples1)){
      # print('increase nrow')
      new_rows <- nrow(samples2)
      samples1 <- rbind(samples1, matrix(NA, nrow = new_rows, ncol = ncol(samples1)))
      samples2 <- rbind(samples2, matrix(NA, nrow = new_rows, ncol = ncol(samples2)))
    }
    samples1[current_nsamples1+1,] <- chain_state1
    samples2[current_nsamples1,] <- chain_state2
    current_nsamples1 <- current_nsamples1 + 1
    # stop after max(K, tau) steps
    if (iter >= max(meetingtime, K)){
      finished <- TRUE
    }
  }
  samples1 <- samples1[1:current_nsamples1,,drop=F]
  samples2 <- samples2[1:(current_nsamples1-1),,drop=F]
  return(list(samples1 = samples1, samples2 = samples2,
              meetingtime = meetingtime, iteration = iter, finished = finished))
}


## function to continue coupled chains until step K
## c_chain should be the output of coupled_chains
## and K should be more than c_chain$iteration, otherwise returns c_chain
#'@rdname continue_coupled_chains
#'@title Continue coupled MCMC chains up to K steps
#'@description ## function to continue coupled chains until step K
#' c_chain should be the output of coupled_chains
#' and K should be more than c_chain$iteration, otherwise returns c_chain
#'@export
continue_coupled_chains <- function(c_chain, single_kernel, K = 1, ...){
  if (K <= c_chain$iteration){
    ## nothing to do
    return(c_chain)
  } else {
    niterations <- K - c_chain$iteration
    chain_state1 <- c_chain$samples1[c_chain$iteration+1,]
    p <- length(chain_state1)
    samples1 <- matrix(nrow = niterations, ncol = p)
    samples2 <- matrix(nrow = niterations, ncol = p)
    for (iteration in 1:niterations){
      chain_state1 <- single_kernel(chain_state1, iteration)$chain_state
      samples1[iteration,] <- chain_state1
      samples2[iteration,] <- chain_state1
    }
    c_chain$samples1 <- rbind(c_chain$samples1, samples1)
    c_chain$samples2 <- rbind(c_chain$samples2, samples2)
    c_chain$iteration <- K
    return(c_chain)
  }
}



# from h_bar --------------------------------------------------------------

#'@rdname H_bar
#'@title Compute unbiased estimators from coupled chains
#'@description Compute the proposed unbiased estimators, for each of the element
#'in the list 'c_chains'. The integral of interest is that of the function h,
#'which can be multivariate. The estimator uses the variance reduction technique
#'whereby the estimator is the MCMC average between times k and K, with probability
#'going to one as k increases.
#'@export
H_bar <- function(c_chains, h = function(x) x, k = 0, K = 1){
  maxiter <- c_chains$iteration
  if (k > maxiter){
    print("error: k has to be less than the horizon of the coupled chains")
    return(NULL)
  }
  if (K > maxiter){
    print("error: K has to be less than the horizon of the coupled chains")
    return(NULL)
  }
  # test the dimension of h(X)
  p <- length(h(c_chains$samples1[1,]))
  h_of_chain <- apply(X = c_chains$samples1[(k+1):(K+1),,drop=F], MARGIN = 1, FUN = h)
  if (is.null(dim(h_of_chain))){
    h_of_chain <- matrix(h_of_chain, ncol = 1)
  } else {
    h_of_chain <- t(h_of_chain)
  }
  H_bar <- apply(X = h_of_chain, MARGIN = 2, sum)
  if (c_chains$meetingtime <= k + 1){
    # nothing else to add
  } else {
    deltas <- matrix(0, nrow = maxiter - k + 1, ncol = p)
    deltas_term <- rep(0, p)
    for (t in k:min(maxiter-1, c_chains$meetingtime-1)){ # t is as in the report, where the chains start at t=0
      coefficient <- min(t - k + 1, K - k + 1)
      delta_tp1 <- h(c_chains$samples1[t + 1 + 1,]) - h(c_chains$samples2[t+1,]) # the +1's are because R starts indexing at 1
      deltas_term <- deltas_term + coefficient * delta_tp1
    }
    H_bar <- H_bar + deltas_term
  }
  return(H_bar / (K - k + 1))
}
