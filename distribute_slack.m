% distribute_slack.m
%
% Originally a function in accfm.m, removed so that it could be accessed by
% other scripts and functions.
function network = distribute_slack(network, network_prev, settings)
% DISTRIBUTE_SLACK distributes generation at slack bus to all generators
% depending on their generation capacity.

    define_constants;
    
    % find all active generators
    gens = find(network.gen(:, GEN_STATUS) > 0);
    
    % find the slack generators
    slack_gen = get_slack_gen(network);
    
    % determine the change in slack generation since previous generation
    slack_change = network.gen(slack_gen, PG) - network_prev.gen(slack_gen, PG);
    
    % accept a small change in slack generation without distribution
    if abs(slack_change) < 1
        return
    end
    
    % determines the share of each generator on the entire capacity
    factors = network.gen(gens, PMAX) / sum(network.gen(gens, PMAX));
    
    % the generation change for each generator
    delta = factors * slack_change;

    % apply the change
    network.gen(gens, PG) = network.gen(gens, PG) + delta;
    
    % run a power flow
    network = runpf(network, settings.mpopt);
    network.pf_count = network.pf_count + 1;

    % it might be that some generators now exceed their capacity
    while ~isempty(find(network.gen(:, PG) > network.gen(:, PMAX), 1)) || ~isempty(find(network.gen(:, PG) < network.gen(:, PMIN) & network.gen(:, GEN_STATUS) == 1, 1))
        % this is the total exceeding generation
        surplus = sum(network.gen(network.gen(:, PG) > network.gen(:, PMAX), PG) - network.gen(network.gen(:, PG) > network.gen(:, PMAX), PMAX));
        
        % this is the total missing generation
        deficit = -sum(network.gen(network.gen(:, PG) < network.gen(:, PMIN) & network.gen(:, GEN_STATUS) == 1, PG) - network.gen(network.gen(:, PG) < network.gen(:, PMIN) & network.gen(:, GEN_STATUS) == 1, PMIN));
        
        % set the generators that exceed their capacity to their maximum
        % output
        network.gen(network.gen(:, PG) > network.gen(:, PMAX), PG) = network.gen(network.gen(:, PG) > network.gen(:, PMAX), PMAX);
        
        % set the generators that fall below their capacity to their
        % minimum output
        network.gen(network.gen(:, PG) < network.gen(:, PMIN) & network.gen(:, GEN_STATUS) == 1, PG) = network.gen(network.gen(:, PG) < network.gen(:, PMIN) & network.gen(:, GEN_STATUS) == 1, PMIN);

        % the overhead generation is shared over the remaining generators
        sp_factor = surplus / sum(network.gen(network.gen(:, PG) < network.gen(:, PMAX), PG));
        if sp_factor > 0
            network.gen(network.gen(:, PG) < network.gen(:, PMAX), PG) = round((1 + sp_factor) * network.gen(network.gen(:, PG) < network.gen(:, PMAX), PG), 4);
        end
        
        % the deficit generation is shared over the remaining generators
        df_factor = deficit / sum(network.gen(network.gen(:, PG) > network.gen(:, PMIN) & network.gen(:, GEN_STATUS) == 1, PG));
        if df_factor > 0
            network.gen(network.gen(:, PG) > network.gen(:, PMIN) & network.gen(:, GEN_STATUS) == 1, PG) = round((1 + df_factor) * network.gen(network.gen(:, PG) > network.gen(:, PMIN) & network.gen(:, GEN_STATUS) == 1, PG), 4);
        end
        
        % this is repeated until there is no exceeding generation
    end

    % run another power flow
    network = runpf(network, settings.mpopt);
    network.pf_count = network.pf_count + 1;
end