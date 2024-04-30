function result_cascade = accfm(network, initial_contingency, settings)
% the AC Cascading Fault Model
%   accfm(network, initial_contingency, settings) runs the AC-CFM in
%   network with initial_contingency and settings
%   result_cascade = accfm( ___ ) returns the cascade result structure

%   AC-CFM
%   Copyright (c) 2020, Matthias Noebels
%   This file is part of AC-CFM.
%   Covered by the 3-clause BSD License (see LICENSE file for details).

    % define matpower constants
    define_constants;

    % define constants for saving summary
    get_constants_accfmsave;
    
    % load empty initial contingency if no other specified
    if ~exist('initial_contingency', 'var') || ~isstruct(initial_contingency)
        initial_contingency = struct;
    end
    
    if ~isfield(initial_contingency, 'buses')
        initial_contingency.buses = [];
    end
    
    if ~isfield(initial_contingency, 'branches')
        initial_contingency.branches = [];
    end
    
    if ~isfield(initial_contingency, 'gens')
        initial_contingency.gens = [];
    end
    
    startTime = tic;
    
    % ensure there are no components in the contingency that don't exist
    initial_contingency.buses(initial_contingency.buses > size(network.bus, 1)) = [];
    initial_contingency.branches(initial_contingency.branches < 1 | initial_contingency.branches > size(network.branch, 1)) = [];
    initial_contingency.gens(initial_contingency.gens > size(network.gen, 1)) = [];
    
    % load default settings if no other specified
    if ~exist('settings', 'var') || ~isstruct(settings)
        settings = get_default_settings();
    end

    % add custom fields for identification of elements after extracting
    % islands
    network.bus_id = (1:size(network.bus, 1)).';
    network.gen_id = (1:size(network.gen, 1)).';
    network.branch_id = (1:size(network.branch, 1)).';
    
    % add custom fields for result variables
    network.branch_tripped = zeros(size(network.branch, 1), settings.max_recursion_depth);
    network.bus_tripped = zeros(size(network.bus, 1), settings.max_recursion_depth);
    network.bus_uvls = zeros(size(network.bus, 1), settings.max_recursion_depth);
    network.bus_ufls = zeros(size(network.bus, 1), settings.max_recursion_depth);
    network.gen_tripped = zeros(size(network.gen, 1), settings.max_recursion_depth);
    network.load = zeros(settings.max_recursion_depth, 1);
    network.generation_before = sum(network.gen(:, PG));
    network.pf_count = 0;
    
    % add output structure
    network.accfm_summary = struct();
    network.accfm_summary.n_islands = 1; % Initially we have one island
    network.accfm_summary.n_cascades = 0;
    
    branches = zeros(size(network.branch, 1), 6); % Create structure with branch status
    branch = struct(); % Store information about branches
    branch.id = 0; % Assign ID
    branch.from = 0; % From bus
    branch.to = 0; % To bus
    branch.status = 0;% Status - 0: disconnected, 1: connected
    branch.failure_mode = zeros(1, settings.max_recursion_depth); % Failure mode experienced at each recursion
    branch.dP = zeros(1, settings.max_recursion_depth); % Amount by which active power threshold was exceed at each recursion
    
    branches = repmat(branch, 1, length(network.branch(:, 1)));

    for i=1:length(branches) % Assign IDs and to/from info to each branch
        branches(i).id = i; % Assign ID
        branches(i).to = network.branch(i, 1); % From bus
        branches(i).from = network.branch(i, 2); % To bus
        branches(i).status = network.branch(i, 11); % Status - 0: disconnected, 1: connected
    end
    
    bus = struct(); % Store information about busses
    bus.id = 0; % Assign ID
    bus.type = 0; % Bus type - 1: PQ, 2: PV, 3: Reference, 4: Isolated
    bus.status = 1; % Status - 0: disconnected, 1: connected, 2: connected with load shed
    bus.ls_applied = zeros(2, settings.max_recursion_depth); % Load shed applied at each recursion
    bus.failure_mode = zeros(1, settings.max_recursion_depth); % Failure mode experienced at each recursion
    bus.dG = zeros(1, settings.max_recursion_depth); % Amount by which generation threshold was exceed at each recursion
    bus.dP = zeros(1, settings.max_recursion_depth); % Amount by which active power threshold was exceed at each recursion
    bus.dQ = zeros(1, settings.max_recursion_depth); % Amount by which real power threshold was exceed at each recursion
    bus.dV = zeros(1, settings.max_recursion_depth); % Amount by which voltage threshold was exceed at each recursion
    
    busses = repmat(bus, 1, size(network.bus, 1));

    for i=1:length(busses) % Assign IDs to each bus
        busses(i).id = network.bus(i, 1); % Assign ID
        busses(i).type = network.bus(i, 2); % Assign type
    end
    
    network.accfm_summary.branches = branches;
    network.accfm_summary.busses = busses;

    % add custom fields to include in MATPOWER case structs
    settings.custom.bus{1} = {'bus_id', 'bus_tripped', 'bus_uvls', 'bus_ufls'};
    settings.custom.gen{1} = {'gen_id', 'gen_tripped'};
    settings.custom.branch{1} = {'branch_id', 'branch_tripped'};
    
    % get load before cascade
    load_initial = sum(network.bus(:, PD));
    
    % initialise cascade graph
    network.G = digraph();
    network.G = addnode(network.G, table({'root'}, size(network.bus, 1), {'root'}, load_initial, length(find(network.gen(:, GEN_STATUS) == 1)), length(find(network.branch(:, BR_STATUS) == 1)), 'VariableNames', {'Name', 'Buses', 'Type', 'Load', 'Generators', 'Lines'}));
    
    % apply initial contingency
    network.bus(initial_contingency.buses, BUS_TYPE) = NONE;
    network.branch(initial_contingency.branches, BR_STATUS) = 0;
    network.gen(initial_contingency.gens, GEN_STATUS) = 0;
    
    network.G = addnode(network.G, table({'event'}, size(network.bus, 1), {'event'}, load_initial, length(find(network.gen(:, GEN_STATUS) == 1)), length(find(network.branch(:, BR_STATUS) == 1)), 'VariableNames', {'Name', 'Buses', 'Type', 'Load', 'Generators', 'Lines'}));
    network.G = addedge(network.G, table({'root' 'event'}, {'EV'}, 1, 1, NaN, 'VariableNames', {'EndNodes', 'Type', 'Weight', 'Base', 'LS'}));
    
    % disable MATLAB warnings
    warning('off', 'MATLAB:nearlySingularMatrix');
    warning('off', 'MATLAB:singularMatrix');
    
    % start the recursion
    result_cascade = apply_recursion(network, settings);
    
    % enable MATLAB warnings
    warning('on', 'MATLAB:nearlySingularMatrix');
    warning('on', 'MATLAB:singularMatrix');
    
    % get load after cascade
    load_final = sum(result_cascade.bus(:, PD));
    
    % calculate ls
    result_cascade.ls_total =  (1 - load_final / load_initial);
    result_cascade.ls_ufls = sum(result_cascade.G.Edges.LS(strcmp(result_cascade.G.Edges.Type, 'UFLS'))) / load_initial;
    result_cascade.ls_uvls = sum(result_cascade.G.Edges.LS(strcmp(result_cascade.G.Edges.Type, 'UVLS'))) / load_initial;
    result_cascade.ls_vcls = sum(result_cascade.G.Edges.LS(strcmp(result_cascade.G.Edges.Type, 'VC'))) / load_initial;
    result_cascade.ls_opf = sum(result_cascade.G.Edges.LS(strcmp(result_cascade.G.Edges.Type, 'OPF'))) / load_initial;
    result_cascade.ls_tripped = result_cascade.ls_total - result_cascade.ls_ufls - result_cascade.ls_uvls - result_cascade.ls_vcls - result_cascade.ls_opf;

    result_cascade.elapsed = toc(startTime);
    
    % in verbose mode, display graph
    if settings.verbose
        fprintf('Cascade halted. Elapsed time: %.2fs\n', result_cascade.elapsed);
        fprintf('Total load shedding: %.2f%%\n', 100 * result_cascade.ls_total);
        fprintf('Load shedding UFLS: %.2f%% \n', 100 * result_cascade.ls_ufls);
        fprintf('Load shedding UVLS: %.2f%% \n', 100 * result_cascade.ls_uvls);
        fprintf('Load shedding VCLS: %.2f%% \n', 100 * result_cascade.ls_vcls);
        fprintf('Load shedding non-converging OPF: %.2f%% \n', 100 * result_cascade.ls_opf);
        fprintf('Load shedding tripped: %.2f%% \n', 100 * result_cascade.ls_tripped);
        
        plot_cascade_graph(result_cascade);
    end
    
end

function network = apply_recursion(network, settings, i, k, Gnode_parent)

    % define MATPOWER constants
    define_constants;
    
    % define constants for saving summary
    get_constants_accfmsave;

    % default values
    if ~exist('i', 'var')
        i = 1;
    end
    
    if ~exist('k', 'var')
        k = 0;
    end
    
    if ~exist('Gnode_parent', 'var')
        Gnode_parent = 'event';
    end
    
    % error if iteration limit reached
    if i + k > settings.max_recursion_depth
        error('Iteration limit reached');
    end
    
    network.accfm_summary.n_cascades = network.accfm_summary.n_cascades + 1; % Increment number of cascade steps

    % find all islands
    [groups, isolated] = find_islands(network);
    isolated = num2cell(isolated);

    % combine islands and isolated buses
    if size(groups) == 0
        %islands = {isolated{:}};
        islands = isolated(:);
    else
        islands = [groups(:)', isolated(:)'];
        %islands = {groups{:}, isolated{:}};
    end

    network.accfm_summary.n_islands = network.accfm_summary.n_islands + length(islands); % Increment number of islands

    % if there is more than one island, iterate through all of them
    % SIBLING CASE
    if length(islands) > 1

        if settings.verbose
            fprintf(repmat(' ', 1, i))
            fprintf('%d islands and %d isolated nodes detected\n', length(groups), length(isolated));
        end

        for j = 1:length(islands)
            
            if settings.verbose
                fprintf(repmat(' ', 1, i))
                fprintf('Island: [');
                fprintf(repmat(' %d', 1, size(islands{j}, 1)), network.bus(islands{j}, BUS_I));
                fprintf(' ]\n');
            end
            
            % extract the current island
            island = extract_islands(network, islands, j, settings.custom);
            
            % reset bus types to PV for all generating buses
            island.bus(island.bus(:, BUS_TYPE) == PQ & ismember(island.bus(:, BUS_I), island.gen(:, GEN_BUS)), BUS_TYPE) = PV;
            
            % initialise result variables
            island.load = zeros(settings.max_recursion_depth, 1);
            island.generation_before = sum(island.gen(:, PG));
            island.pf_count = 0;
            
            Gnode_name = get_hash();
            network.G = addnode(network.G, table({Gnode_name}, size(island.bus, 1), {''}, sum(island.bus(:, PD)), length(find(island.gen(:, GEN_STATUS) == 1)), length(find(island.branch(:, BR_STATUS) == 1)), 'VariableNames', {'Name', 'Buses', 'Type', 'Load', 'Generators', 'Lines'}));
            network.G = addedge(network.G, table({Gnode_parent Gnode_name}, {'ISL'}, 1, 1, NaN, 'VariableNames', {'EndNodes', 'Type', 'Weight', 'Base', 'LS'}));
            island.G = network.G;
            
            % apply recursion to every island
            island = apply_recursion(island, settings, i, 0, Gnode_name);
            
            % store result variables - Added code to dynamically shape arrays to appropriate size
            network.bus(ismember(network.bus_id, island.bus_id), :) = island.bus(:, 1:length(network.bus(1, :)));
            network.bus_tripped(ismember(network.bus_id, island.bus_id), :) = island.bus_tripped;
            network.bus_uvls(ismember(network.bus_id, island.bus_id), :) = island.bus_uvls;
            network.bus_ufls(ismember(network.bus_id, island.bus_id), :) = island.bus_ufls;
            network.gen(ismember(network.gen_id, island.gen_id), :) = island.gen(:, 1:length(network.gen(1, :)));
            network.gen_tripped(ismember(network.gen_id, island.gen_id), :) = island.gen_tripped;
            network.branch(ismember(network.branch_id, island.branch_id), :) = island.branch(:, 1:length(network.branch(1, :)));
            network.branch_tripped(ismember(network.branch_id, island.branch_id), :) = island.branch_tripped;

            network.load(i:end) = network.load(i:end) + island.load(i:end);
            
            network.pf_count = network.pf_count + island.pf_count;

            network.accfm_summary.n_cascades = network.accfm_summary.n_cascades + 1; % Increment number of cascade steps
            network.accfm_summary.n_islands = network.accfm_summary.n_islands + length(islands); % Increment number of islands
            
            new_branch_inds = boolean(zeros(1, length(network.accfm_summary.branches))); % Store indices of changed branches
            
            for l=1:length(new_branch_inds) % Find indices of changed branches
                new_branch_inds(l) = ~isequal(island.accfm_summary.branches(l), network.accfm_summary.branches(l));
            end

            new_bus_inds = boolean(zeros(1, length(network.accfm_summary.busses))); % Store indices of changed busses
            
            for l=1:length(new_bus_inds) % Find indices of changed branches
                new_bus_inds(l) = ~isequal(island.accfm_summary.busses(l), network.accfm_summary.busses(l));
            end

            network.accfm_summary.branches(new_branch_inds) = island.accfm_summary.branches(new_branch_inds); % Update branch values
            network.accfm_summary.busses(new_bus_inds) = island.accfm_summary.busses(new_bus_inds); % Update branch values

            network.G = island.G;
        end
        
    % if only one island, apply protection mechanmisms
    elseif length(islands) == 1
        
        Gnode_name = '';
        bus_ind = network.bus(:, BUS_I); % Extract indices of busses

        %network_before = network;
            
        % deactivate all buses if there is
        % - no active generation available
        % - no grid-forming generation available and this is required
        % - no loads connected
        if (sum(network.gen(network.gen(:, PMAX) > 0 & network.gen(:, GEN_STATUS) == 1, PMAX)) == 0) || (~isempty(settings.grid_forming) && isfield(network, 'gentype') && ~any(ismember(network.gentype(network.gen(:, GEN_STATUS) == 1), settings.grid_forming))) || sum(network.bus(:, PD)) == 0

            network.G.Edges.LS(outedges(network.G, Gnode_parent)) = sum(network.bus(:, PD));
            network.G.Nodes.Type(findnode(network.G, Gnode_parent)) = {'failure'};
            network.G.Nodes.Load(findnode(network.G, Gnode_parent)) = 0;
            network.G.Nodes.Generators(findnode(network.G, Gnode_parent)) = 0;
            network.G.Nodes.Lines(findnode(network.G, Gnode_parent)) = 0;
            
            network = trip_nodes(network, network.bus(:, BUS_I));
            network.bus_tripped(:, i) = 1;

            for l=1:length(bus_ind) % Update status of tripped busses
                network.accfm_summary.busses(bus_ind(l)).failure_mode(i) = OTHER;
            end
            
            if settings.verbose
                fprintf(repmat(' ', 1, i - k))
                
                if (~isempty(settings.grid_forming) && isfield(network, 'gentype') && ~any(ismember(network.gentype(network.gen(:, GEN_STATUS) == 1), settings.grid_forming)))
                    fprintf(' No grid-forming generation available.');
                elseif sum(network.gen(network.gen(:, PMAX) > 0 & network.gen(:, GEN_STATUS) == 1, PMAX)) == 0
                    fprintf(' No generation available.');
                end
                
                if sum(network.bus(:, PD)) == 0
                    fprintf(' No load connected.');
                end
                    
                fprintf('\n\n');
            end
        end
            
        % only proceed if there are active buses
        if size(network.bus(network.bus(:, BUS_TYPE) ~= NONE), 1) > 0
            
            % reset variables
            conditions_changed = 0;
            exceeded_lines = [];
            exceeded_buses = [];
            exceeded_gens_p = [];
            exceeded_gens_q = [];

            % make sure there is a reference bus
            network = add_reference_bus(network);
            
            % number of reference generators
            number_of_slack_gens = length(get_slack_gen(network));
            
            % model cannot deal with multiple reference buses
            if number_of_slack_gens > 1
                error("Multiple reference buses in one island");
                        
            % if no PQ buses (and thus no reference bus) are available, e.g. due to OXL/UXL, apply VCLS
            elseif number_of_slack_gens == 0
                [network, Gnode_parent] = apply_vcls(network, settings, Gnode_parent, i, k);
                conditions_changed = 1;
            end
            
            if ~conditions_changed
                try
                    % keep previous power flow
                    network_prev = network;
                    
                    % run PF
                    network = runpf(network, settings.mpopt);
                    network.pf_count = network.pf_count + 1;

                    % distribute slack bus over all generators
                    network = distribute_slack(network, network_prev, settings);
                catch
                    % sometimes it gives an error instead of non converging
                    % in this case set success = 0 and continue
                    network.success = 0;
                end

                % PF did not converge
                if ~network.success
                    [network, Gnode_parent] = apply_vcls(network, settings, Gnode_parent, i, k);
                    conditions_changed = 1;
                end
            end
            
            %% UFLS / OFGS
            
            % PF converged
            if network.success && ~conditions_changed

                sum_d = sum(network.bus(:, PD));

                dG = sum(network.gen(:, PG)) - sum(network_prev.gen(:, PG));
                
                gens = find(network.gen(:, GEN_STATUS) > 0);
                sum_g = sum(network.gen(gens, PG));
                sum_gmax = sum(network.gen(gens, PMAX));

                % generation increased
                if dG > 0 && sum_d > 0

                    % change within tolerance and doesn't exceed limits
                    if round(sum_gmax, 2) >= round(sum_g, 2) && (dG <= settings.dP_limit * (sum_g - dG) || dG < 1)
                    %if all(round(network.gen(gens, PMAX), 2) >= round(network.gen(gens, PG), 2)) && (dG <= settings.dP_limit * (sum_g - dG) || dG < 1)
                        
                        if settings.verbose
                            fprintf(repmat(' ', 1, i - k))
                            fprintf(' Demand increased by %.1f%% (limit is %.1f%%) and generation capacity is met. Distribute slack generation.\n', dG / (sum_g - dG) * 100, settings.dP_limit * 100);
                        end
                        
                    % changes outside tolerance or limits exceeded
                    else
                        % apply UFLS
                        sum_gtarget = min(sum_gmax, (sum_g - dG) * (1 + settings.dP_limit));
                        
                        % calculate how much load can be supplied including
                        % overhead factor
                        ls_factor = sum_gtarget / (1 + settings.P_overhead) / sum_d;
                        
                        % if losses are high compared to demand, set to 50%
                        ls_factor = round(ls_factor, 5);
                        if ls_factor >= 1
                            ls_factor = 0;
                        end
                        
                        network.bus(:, [PD QD]) = ls_factor * network.bus(:, [PD QD]);
                        network.bus_ufls(:, i) = 1 - ls_factor;
                        
                        network.accfm_summary.dG(i) = dG; % Store change in generation
                        
                        for l=1:length(bus_ind) % Store amount of load shed at each bus
                            network.accfm_summary.busses(bus_ind(l)).ls_applied(:, i) = (1 - ls_factor)*network.bus(network.bus(:, BUS_I) == bus_ind(l), [PD QD]);
                            network.accfm_summary.busses(bus_ind(l)).status = LOAD_SHED;
                            network.accfm_summary.busses(bus_ind(l)).failure_mode(i) = UFLS;
                        end
                        
                        network = runpf(network, settings.mpopt);
                        network.pf_count = network.pf_count + 1;

                        conditions_changed = 1;

                        if settings.verbose
                            fprintf(repmat(' ', 1, i - k))
                            fprintf(' Demand increased by %.1f%% (limit is %.1f%%) or generation capacity is not met. Perform underfrequency load shedding of %.1f%%.\n', dG / (sum_g - dG) * 100, settings.dP_limit * 100, (1 - ls_factor) * 100);
                        end
                        
                        Gnode_name = get_hash();
                        network.G = addnode(network.G, table({Gnode_name}, size(network.bus, 1), {''}, sum(network.bus(:, PD)), length(find(network.gen(:, GEN_STATUS) == 1)), length(find(network.branch(:, BR_STATUS) == 1)), 'VariableNames', {'Name', 'Buses', 'Type', 'Load', 'Generators', 'Lines'}));
                        network.G = addedge(network.G, table({Gnode_parent Gnode_name}, {'UFLS'}, (1 - ls_factor), 1, (1 - ls_factor) * sum_d, 'VariableNames', {'EndNodes', 'Type', 'Weight', 'Base', 'LS'}));
                        Gnode_parent = Gnode_name;
                    end

                % dSlack < 0, demand decreased
                elseif dG < 0
                    
                    % change within tolerance
                    if -dG <= settings.dP_limit * (sum_g - dG)

                        if settings.verbose
                            fprintf(repmat(' ', 1, i - k))
                            fprintf(' Demand decreased by %.1f%% (limit is %.1f%%). Distribute slack generation.\n', -dG / (sum_g - dG) * 100, settings.dP_limit * 100);
                        end
                    
                    % changes outside tolerance
                    else
                        % apply OFGS
                        
                        % determine what generators to shed
                        [~, ind] = sort(network.gen(:, PMAX) ./ network.gen(:, GEN_STATUS));
                        
                        gens_to_shed = find(cumsum(network.gen(ind, PG)) > -dG, 1) - 1;
                        if gens_to_shed == 0
                            gens_to_shed = 1;
                        elseif isempty(gens_to_shed)
                            gens_to_shed = 1;
                        end
                        
                        network.gen(ind(1:gens_to_shed), [PG QG GEN_STATUS]) = zeros(gens_to_shed, 3);
                        network.gen_tripped(ind(1:gens_to_shed), i) = 1;
                        
                        buses_with_active_generation = unique(network.gen(network.gen(:, GEN_STATUS) == 1, GEN_BUS));
                        pv_buses = network.bus(network.bus(:, BUS_TYPE) == PV, BUS_I);
                        network.bus(ismember(network.bus(:, BUS_I), setdiff(pv_buses, buses_with_active_generation)), BUS_TYPE) = PQ;
                        
                        network = add_reference_bus(network);
                        
                        for l=1:gens_to_shed % Store index at which generator was shed and update status
                            network.accfm_summary.busses(network.gen(ind(l), GEN_BUS)).status = FAILED;
                            network.accfm_summary.busses(network.gen(ind(l), GEN_BUS)).failure_mode(i) = OFGS;
                            network.accfm_summary.busses(network.gen(ind(l), GEN_BUS)).dG(i) = dG; % Store change in generation
                        end

                        if ~isempty(find(network.gen(:, GEN_STATUS) == 1, 1))
                            network = runpf(network, settings.mpopt);
                            network.pf_count = network.pf_count + 1;
                        end

                        conditions_changed = 1;

                        if settings.verbose
                            fprintf(repmat(' ', 1, i - k))
                            fprintf(' Demand decreased by %.1f%% (limit is %.1f%%). Tripping %d smallest generators.\n', -(dG / (sum_g - dG)) * 100, settings.dP_limit * 100, gens_to_shed);
                        end
                        
                        Gnode_name = get_hash();
                        network.G = addnode(network.G, table({Gnode_name}, size(network.bus, 1), {''}, sum(network.bus(:, PD)), length(find(network.gen(:, GEN_STATUS) == 1)), length(find(network.branch(:, BR_STATUS) == 1)), 'VariableNames', {'Name', 'Buses', 'Type', 'Load', 'Generators', 'Lines'}));
                        network.G = addedge(network.G, table({Gnode_parent Gnode_name}, {'OFGS'}, length(gens_to_shed), size(network.gen, 1), NaN, 'VariableNames', {'EndNodes', 'Type', 'Weight', 'Base', 'LS'}));
                        Gnode_parent = Gnode_name;
                    end
                end
            end
            
            
            % proceed with further protection mechanisms only if conditions
            % haven't changed. Otherwise recalculate PF
            if ~conditions_changed
                
                % get exceeded branches, buses and generators
                exceeded_lines = find(round(mean([sqrt(network.branch(:, PF).^2 + network.branch(:, QF).^2) sqrt(network.branch(:, PT).^2 + network.branch(:, QT).^2)], 2), 5) > round(network.branch(:, RATE_A) * 1.01, 5));
                exceeded_buses = find(network.bus(:, BUS_TYPE) ~= NONE & (round(network.bus(:, VM), 3) < network.bus(:, VMIN)) & (network.bus(:, PD) > 0 | network.bus(:, QD) > 0));
                exceeded_gens_p = find(round(network.gen(:, PG), 5) < network.gen(:, PMIN) & network.gen(:, GEN_STATUS) == 1);
                exceeded_gens_q = find((round(network.gen(:, QG) - network.gen(:, QMIN), 5) < -abs(settings.Q_tolerance * network.gen(:, QMIN)) | round(network.gen(:, QG) - network.gen(:, QMAX), 5) > abs(settings.Q_tolerance * network.gen(:, QMAX))) & network.gen(:, GEN_STATUS) == 1);
                
                % compute distances from threshold boundaries
                threshold_deltas_lines = round(mean([sqrt(network.branch(exceeded_lines, PF).^2 + network.branch(exceeded_lines, QF).^2) sqrt(network.branch(exceeded_lines, PT).^2 + network.branch(exceeded_lines, QT).^2)], 2), 5) - round(network.branch(exceeded_lines, RATE_A) * 1.01, 5);
                threshold_deltas_busses = (round(network.bus(exceeded_buses, VM), 3) - network.bus(exceeded_buses, VMIN));
                threshold_deltas_p = (round(network.gen(exceeded_gens_p, PG), 5) - network.gen(exceeded_gens_p, PMIN));
                l_bound_q = round(network.gen(exceeded_gens_q, QG) - network.gen(exceeded_gens_q, QMIN), 5) + abs(settings.Q_tolerance * network.gen(exceeded_gens_q, QMIN)); % Check lower boundary. Will be less than 0 if exceeded
                u_bound_q = -1*round(network.gen(exceeded_gens_q, QG) + network.gen(exceeded_gens_q, QMAX), 5) + abs(settings.Q_tolerance * network.gen(exceeded_gens_q, QMAX)); % Check upper boundary. Will be less than 0 if exceeded
                [threshold_deltas_q, sgn] = min([u_bound_q, zeros(size(l_bound_q, 1), 1), l_bound_q]); % Index is used to correct sign
                threshold_deltas_q = (sgn - 2).*threshold_deltas_q; % Correct sign so the upper bound is positive

                %% O/UXL
                
                % exceeded generator Q limits
                if ~isempty(exceeded_gens_q)
                    % O/UXL
                    
                    if size(network.bus, 1) == 1
                        ls_factor = sum(network.gen(gens, QMAX)) / sum(network.gen(gens, QG));
                        fail_mode = OXL;

                        if ls_factor < 0
                            ls_factor = sum(network.gen(gens, QMIN)) / sum(network.gen(gens, QG));
                            fail_mode = UXL;
                        end
                        
                        network.bus(:, [PD QD]) = ls_factor * network.bus(:, [PD QD]);
                        
                        % Save the over power threshold, bus status, and amount of load shed
                        network.accfm_summary.busses(bus_ind(1)).dQ(i) = threshold_deltas_q;
                        network.accfm_summary.busses(bus_ind(1)).ls_applied(1, i) = (1 - ls_factor) * network.bus(:, [PD QD]);
                        network.accfm_summary.busses(bus_ind(1)).status = LOAD_SHED;
                        network.accfm_summary.busses(bus_ind(1)).failure_mode(i) = fail_mode;
                    else
                        % convert buses to PQ
                        network.bus(network.bus(:, BUS_TYPE) ~= NONE & ismember(network.bus(:, BUS_I), network.gen(exceeded_gens_q, GEN_BUS)), BUS_TYPE) = PQ;

                        % set Q output to closest limit
                        network.gen(intersect(exceeded_gens_q, find(network.gen(:, QG) < network.gen(:, QMIN))), QG) = network.gen(intersect(exceeded_gens_q, find(network.gen(:, QG) < network.gen(:, QMIN))), QMIN);
                        network.gen(intersect(exceeded_gens_q, find(network.gen(:, QG) > network.gen(:, QMAX))), QG) = network.gen(intersect(exceeded_gens_q, find(network.gen(:, QG) > network.gen(:, QMAX))), QMAX);
                    
                        ind_changed = find(network.bus(:, BUS_TYPE) ~= NONE & ismember(network.bus(:, BUS_I), network.gen(exceeded_gens_q, GEN_BUS)));

                        for l=1:length(ind_changed) % Save bus status and amount of load shed
                            network.accfm_summary.busses(ind_changed(l)).ls_applied(2, i)  = threshold_deltas_q(l);
                            network.accfm_summary.busses(ind_changed(l)).dQ(i) = threshold_deltas_q(l);
                            network.accfm_summary.busses(ind_changed(l)).type = PQ;
                            network.accfm_summary.busses(ind_changed(l)).status = LOAD_SHED;
                            if threshold_deltas_q(l) < 0 % If negative then UXL was applied
                                network.accfm_summary.busses(network.bus(ind_changed(l), BUS_I)).failure_mode(i) = UXL;
                            else % Otherwise OXL was applied
                                network.accfm_summary.busses(network.bus(ind_changed(l), BUS_I)).failure_mode(i) = OXL;
                            end
                        end
                    end
                    
                    if settings.verbose
                        fprintf(repmat(' ', 1, i - k))
                        fprintf(' Q outside limits at generators at buses');
                        fprintf(repmat(' %d', 1, length(exceeded_gens_q)), network.gen(exceeded_gens_q, GEN_BUS));
                        fprintf('\n');
                    end
                    
                    if isempty(Gnode_name)
                        Gnode_name = get_hash();
                        network.G = addnode(network.G, table({Gnode_name}, size(network.bus, 1), {''}, sum(network.bus(:, PD)), length(find(network.gen(:, GEN_STATUS) == 1)), length(find(network.branch(:, BR_STATUS) == 1)), 'VariableNames', {'Name', 'Buses', 'Type', 'Load', 'Generators', 'Lines'}));
                    end
                    network.G = addedge(network.G, table({Gnode_parent Gnode_name}, {'XL'}, length(exceeded_gens_q), size(network.gen, 1), NaN, 'VariableNames', {'EndNodes', 'Type', 'Weight', 'Base', 'LS'}));
                end
                
                %% ULGT
                
                % exceeded lower generator P limit
                if ~isempty(exceeded_gens_p)
                    % ULGT
                    
                    network.gen(exceeded_gens_p, [PG QG GEN_STATUS]) = zeros(length(exceeded_gens_p), 3);
                    
                    network.gen_tripped(exceeded_gens_p, i) = 1;

                    buses_with_active_generation = unique(network.gen(network.gen(:, GEN_STATUS) == 1, GEN_BUS));
                    pv_buses = network.bus(network.bus(:, BUS_TYPE) == PV, BUS_I);
                    network.bus(ismember(network.bus(:, BUS_I), setdiff(pv_buses, buses_with_active_generation)), BUS_TYPE) = PQ;

                    network = add_reference_bus(network);
                    
                    for l=1:length(exceeded_gens_p) % Save bus state and over threshold amount
                        network.accfm_summary.busses(network.bus(exceeded_gens_p(l), BUS_I)).dP(i) = threshold_deltas_p(l);
                        network.accfm_summary.busses(network.bus(exceeded_gens_p(l), BUS_I)).status = FAILED;
                        network.accfm_summary.busses(network.bus(exceeded_gens_p(l), BUS_I)).failure_mode(i) = ULGT;
                    end

                    if settings.verbose
                        fprintf(repmat(' ', 1, i - k))
                        fprintf(' Generators at buses tripped due to underload');
                        fprintf(repmat(' %d', 1, length(exceeded_gens_p)), network.gen(exceeded_gens_p, GEN_BUS));
                        fprintf('\n');
                    end
                    
                    if isempty(Gnode_name)
                        Gnode_name = get_hash();
                        network.G = addnode(network.G, table({Gnode_name}, size(network.bus, 1), {''}, sum(network.bus(:, PD)), length(find(network.gen(:, GEN_STATUS) == 1)), length(find(network.branch(:, BR_STATUS) == 1)), 'VariableNames', {'Name', 'Buses', 'Type', 'Load', 'Generators', 'Lines'}));
                    end
                    network.G = addedge(network.G, table({Gnode_parent Gnode_name}, {'ULGT'}, length(exceeded_gens_p), size(network.gen, 1), NaN, 'VariableNames', {'EndNodes', 'Type', 'Weight', 'Base', 'LS'}));
                end
                
                %% UVLS
                
                % exceeded buses
                if ~isempty(exceeded_buses)
                    % UVLS

                    if settings.verbose
                        fprintf(repmat(' ', 1, i - k))
                        fprintf(' Voltage outside limits at buses');
                        fprintf(repmat(' %d', 1, length(exceeded_buses)), network.bus(exceeded_buses, BUS_I));
                        fprintf('\n');
                    end

                    % calculate how often uvls has been applied at each bus
                    uvls_steps_applied = sum(network.bus_uvls ~= 0, 2);

                    % apply undervoltage load shedding
                    buses_uvls_apply = intersect(exceeded_buses, find(uvls_steps_applied < settings.uvls_max_steps));
                    
                    load_initial = sum(network.bus(:, PD));

                    if ~isempty(buses_uvls_apply)
                        network.bus_uvls(buses_uvls_apply, i) = (settings.uvls_per_step ./ (1 - settings.uvls_per_step * uvls_steps_applied(buses_uvls_apply)));
                        
                        network.bus(buses_uvls_apply, [PD QD]) = (1 - network.bus_uvls(buses_uvls_apply, i)) .* network.bus(buses_uvls_apply, [PD QD]);
                        
                        for l=1:length(buses_uvls_apply) % Save bus state and over threshold amount
                            network.accfm_summary.busses(network.bus(buses_uvls_apply(l), BUS_I)).dV(i) = threshold_deltas_busses(l);
                            network.accfm_summary.busses(network.bus(buses_uvls_apply(l), BUS_I)).ls_applied(:, i) = (network.bus_uvls(buses_uvls_apply(l), i)) .* network.bus(buses_uvls_apply(l), [PD QD]);
                            network.accfm_summary.busses(network.bus(buses_uvls_apply(l), BUS_I)).status = LOAD_SHED;
                            network.accfm_summary.busses(network.bus(buses_uvls_apply(l), BUS_I)).failure_mode(i) = UVLS;
                        end

                        if settings.verbose
                            fprintf(repmat(' ', 1, i - k))
                            fprintf(' Undervoltage load shedding applied at buses');
                            fprintf(repmat(' %d', 1, length(buses_uvls_apply)), network.bus(buses_uvls_apply, BUS_I));
                            fprintf('\n');
                        end
                    end

                    % trip buses with exceeded uvls steps
                    buses_uvls_exceeded = intersect(exceeded_buses, setdiff(find(sum(network.bus_uvls ~= 0, 2) >= settings.uvls_max_steps), buses_uvls_apply));

                    if ~isempty(buses_uvls_exceeded)
                        network.bus(buses_uvls_exceeded, PD) = 0;
                        network.bus(buses_uvls_exceeded, QD) = 0;
                        
                        network.bus_uvls(buses_uvls_exceeded, i) = 1;
                        
                        for l=1:length(buses_uvls_exceeded) % Save bus state
                            network.accfm_summary.busses(network.bus(buses_uvls_apply(l), BUS_I)).ls_applied(:, i) = NaN;
                            network.accfm_summary.busses(network.bus(buses_uvls_exceeded(l), BUS_I)).status = FAILED;
                            network.accfm_summary.busses(network.bus(buses_uvls_exceeded(l), BUS_I)).failure_mode(i) = UVLS;
                        end

                        if settings.verbose
                            fprintf(repmat(' ', 1, i - k))
                            fprintf(' Loads tripped due to undervoltage at buses');
                            fprintf(repmat(' %d', 1, length(buses_uvls_exceeded)), network.bus(buses_uvls_exceeded, BUS_I));
                            fprintf('\n');
                        end
                    end
                    
                    if ~isempty(buses_uvls_apply) || ~isempty(buses_uvls_exceeded)
                        if isempty(Gnode_name)
                            Gnode_name = get_hash();
                            network.G = addnode(network.G, table({Gnode_name}, size(network.bus, 1), {''}, sum(network.bus(:, PD)), length(find(network.gen(:, GEN_STATUS) == 1)), length(find(network.branch(:, BR_STATUS) == 1)), 'VariableNames', {'Name', 'Buses', 'Type', 'Load', 'Generators', 'Lines'}));
                        end
                        network.G = addedge(network.G, table({Gnode_parent Gnode_name}, {'UVLS'}, length(buses_uvls_apply) + length(buses_uvls_exceeded), size(network.bus, 1), load_initial - sum(network.bus(:, PD)), 'VariableNames', {'EndNodes', 'Type', 'Weight', 'Base', 'LS'}));
                    end
                end
                
                %% OLP
                
                % exceeded lines
                if ~isempty(exceeded_lines)
                    % OLP
                    
                    network.branch(exceeded_lines, BR_STATUS) = 0;
                    network.branch_tripped(exceeded_lines, i) = 1;
                    
                    for l=1:length(exceeded_lines) % Save branch state and overpower threshold amount
                        network.accfm_summary.branches(exceeded_lines(l)).dP(i) = threshold_deltas_lines(l);
                        network.accfm_summary.branches(exceeded_lines(l)).status = FAILED;
                        network.accfm_summary.branches(exceeded_lines(l)).failure_mode(i) = OLP;
                    end

                    if settings.verbose
                        fprintf(repmat(' ', 1, i - k))
                        fprintf(' Exceeded line ratings:');
                        fprintf(repmat(' %d-%d', 1, length(exceeded_lines)), [network.branch(exceeded_lines, 1) network.branch(exceeded_lines, 2)].');
                        fprintf('\n');
                    end
                    
                    if isempty(Gnode_name)
                        Gnode_name = get_hash();
                        network.G = addnode(network.G, table({Gnode_name}, size(network.bus, 1), {''}, sum(network.bus(:, PD)), length(find(network.gen(:, GEN_STATUS) == 1)), length(find(network.branch(:, BR_STATUS) == 1)), 'VariableNames', {'Name', 'Buses', 'Type', 'Load', 'Generators', 'Lines'}));
                    end
                    network.G = addedge(network.G, table({Gnode_parent Gnode_name}, {'OL'}, length(exceeded_lines), size(network.branch, 1), NaN, 'VariableNames', {'EndNodes', 'Type', 'Weight', 'Base', 'LS'}));
                end
                
                if ~isempty(Gnode_name)
                    Gnode_parent = Gnode_name;
                end
            end
            
            if settings.verbose
                fprintf('\n');
            end
            
            %% recursion            
            
            network.load(i) = sum(network.bus(:, PD));
            network.G.Nodes.Load(findnode(network.G, Gnode_parent)) = sum(network.bus(:, PD));
            
            % cascade continues
            if sum(network.bus(:, PD)) > 0 && (conditions_changed || ~isempty(exceeded_lines) || ~isempty(exceeded_buses) || ~isempty(exceeded_gens_p) || ~isempty(exceeded_gens_q))
                % INDUCTION CASE
                network = apply_recursion(network, settings, i + 1, k + 1, Gnode_parent);
                
            % cascade halted or no loads
            else
                % BASE CASE
                network.load(i:end) = sum(network.bus(:, PD));
                
                if network.success == 1
                    network.G.Nodes.Type(findnode(network.G, Gnode_parent)) = {'success'};
                end
            end
        end
    end
end

function hash = get_hash
    symbols = ['a':'z' 'A':'Z' '0':'9'];
    stLength = 20;
    nums = randi(numel(symbols),[1 stLength]);
    hash = symbols (nums);
end

function [network, tripped_lines] = trip_nodes(network, nodes)
% TRIP_NODES deactivates the nodes with the specified bus numbers, sets the
% fixed demand to 0 and trips all branches connected to the nodes.

    define_constants;
    
    % define constants for saving summary
    get_constants_accfmsave;

    % set bus type to isolated
    network.bus(ismember(network.bus(:, BUS_I), nodes), BUS_TYPE) = NONE;
    
    % set fixed demand to 0
    network.bus(ismember(network.bus(:, BUS_I), nodes), PD) = 0;
    network.bus(ismember(network.bus(:, BUS_I), nodes), QD) = 0;
    
    % trip generators
    network.gen(ismember(network.gen(:, GEN_BUS), nodes), GEN_STATUS) = 0;
    
    % trip branches
    network.branch(ismember(network.branch(:, F_BUS), nodes), BR_STATUS) = 0;
    network.branch(ismember(network.branch(:, T_BUS), nodes), BR_STATUS) = 0;
    
    tripped_lines = [find(ismember(network.branch(:, F_BUS), nodes)); find(ismember(network.branch(:, T_BUS), nodes))];
end

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

function slack_gen = get_slack_gen(network)
% GET_SLACK_GEN returns the indices of the slack generators

    define_constants;

    % find all slack buses
    slack_bus = network.bus(network.bus(:, BUS_TYPE) == REF, BUS_I);
    
    slack_gen = zeros(size(slack_bus));
    
    % find all active generators and their buses
    on = find(network.gen(:, GEN_STATUS) > 0);
    gbus = network.gen(on, GEN_BUS);
    
    % go through every slack bus
    for k = 1:length(slack_bus)
        % the slack generator is the first active generator
        temp = find(gbus == slack_bus(k));
        slack_gen(k) = on(temp(1));
    end
end

function [network, Gnode_parent] = apply_vcls(network, settings, Gnode_parent, i, k)
% APPLY_VLCS tries to make an unsolvable power flow solvable by applying
% voltage collapse load shedding
% 
% There are two reasons why a power flow might not be solvable: Q limits 
% exceeded or voltage collapse. This function runs an OPF to find the loads
% that need to be shed in order to make the power flow solvable again.
    
    define_constants;
    
    % define constants for saving summary
    get_constants_accfmsave;
    
    % make a copy of the network, get total load
    network_disp = network;
    load_initial = sum(network.bus(:, PD));

    % ignore line constraints
    network_disp.branch(:, RATE_A) = 0;

    % reduce lower voltage limit
    network_disp.bus(:, VMIN) = 0.2;
    
    % if there is no slack bus, set maximum bus voltage to current
    % voltage. This might be the result of previous O/UXL
    if isempty(find(network_disp.bus(:, BUS_TYPE) == REF, 1))
        network_disp.bus(:, VMAX) = network_disp.bus(:, VM);
        network_disp.gen(network_disp.gen(:, QG) <= network_disp.gen(:, QMIN), [QMIN QMAX]) = network_disp.gen(network_disp.gen(:, QG) <= network_disp.gen(:, QMIN), [QMIN QMIN]);
        network_disp.gen(network_disp.gen(:, QG) >= network_disp.gen(:, QMAX), [QMIN QMAX]) = network_disp.gen(network_disp.gen(:, QG) >= network_disp.gen(:, QMAX), [QMAX QMAX]);
    end

    % force a slack bus to be present
    network_disp = add_reference_bus(network_disp, 1);

    % convert all loads to dispatchable loads
    network_disp = load2disp(network_disp);

    % run OPF and adjust network
    [network, Gnode_parent, opf_success] = apply_opf(network, network_disp, settings, Gnode_parent, i, k);

    % OPF did not converge
    if opf_success == 0 && any(network_disp.gen(:, PMIN) > 0)
        
        % disable generator PMIN limits
        network_disp.gen(network_disp.gen(:, 10) > 0, PMIN) = 0;
        
        % run OPF and adjust network
        [network, Gnode_parent, opf_success] = apply_opf(network, network_disp, settings, Gnode_parent, i, k);
    end
    
    % remove shunt devices if OPF still doesn't converge
    if opf_success == 0
        
        % remove shunt devices
        network_disp.bus(:, BS) = 0;
        
        network_no_shunt = network;
        network_no_shunt.bus(:, BS) = 0;
        
        % run OPF and adjust network
        [network_no_shunt, Gnode_parent, opf_success] = apply_opf(network_no_shunt, network_disp, settings, Gnode_parent, i, k);
        
        if opf_success == 1
            
            if settings.verbose
                fprintf(repmat(' ', 1, i - k))
                fprintf(' Tripping shunt devices');
                fprintf('\n');
            end
            
            shunt_devices = length(find(network.bus(:, BS)));
            network = network_no_shunt;
            
            Gnode_name = get_hash();
            network.G = addnode(network.G, table({Gnode_name}, size(network.bus, 1), {''}, sum(network.bus(:, PD)), length(find(network.gen(:, GEN_STATUS) == 1)), length(find(network.branch(:, BR_STATUS) == 1)), 'VariableNames', {'Name', 'Buses', 'Type', 'Load', 'Generators', 'Lines'}));
            network.G = addedge(network.G, table({Gnode_parent Gnode_name}, {'SH'}, shunt_devices, shunt_devices, NaN, 'VariableNames', {'EndNodes', 'Type', 'Weight', 'Base', 'LS'}));
            Gnode_parent = Gnode_name;
        end
    end
    
    % if it still doesn't converge, then trip the island
    if opf_success == 0
        % trip island
        if settings.verbose
            fprintf(repmat(' ', 1, i - k))
            fprintf(' OPF failed. Check constraints. Island tripped (%d buses).\n', size(network_disp.bus, 1));
        end

        network = trip_nodes(network, network.bus(:, BUS_I));
        network.bus_tripped(:, i) = 1;
        
        bus_ind = network.bus(:, BUS_I); % Get IDs of busses in current island

        for l=1:bus_ind % Update bus status
            network.accfm_summary.busses(l).status = FAILED;
            network.accfm_summary.busses(l).failure_mode(i) = VCLS;
        end

        Gnode_name = get_hash();
        network.G = addnode(network.G, table({Gnode_name}, size(network.bus, 1), {'failure'}, 0, 0, 0, 'VariableNames', {'Name', 'Buses', 'Type', 'Load', 'Generators', 'Lines'}));
        network.G = addedge(network.G, table({Gnode_parent Gnode_name}, {'OPF'}, 1, load_initial, load_initial, 'VariableNames', {'EndNodes', 'Type', 'Weight', 'Base', 'LS'}));
        Gnode_parent = Gnode_name;
    end
end

function [network, Gnode_parent, opf_success] = apply_opf(network, network_disp, settings, Gnode_parent, i, k)
% APPLY_OPF runs an optimal power flow on the modified (dispatchable)
% network_disp and applies any load shedding that occured to network

    define_constants;
    
    % define constants for saving summary
    get_constants_accfmsave;

    load_initial = sum(network.bus(:, PD));

    % use a faster OPF solver if available
    if have_fcn('ipopt')
        results_disp = runopf(network_disp, mpoption(settings.mpopt, 'opf.ac.solver', 'IPOPT'));
    else
        results_disp = runopf(network_disp, settings.mpopt);
    end
    
    opf_success = results_disp.success;

    % OPF converged
    if results_disp.success == 1

        % keep bus voltages and reference bus
        network.bus(:, [BUS_TYPE VM VA]) = results_disp.bus(:, [BUS_TYPE VM VA]);

        % determine which loads to shed
        loads_shed = find(results_disp.gen(:, PMIN) < 0 & round(results_disp.gen(:, PG)) > round(results_disp.gen(:, PMIN)));
        
        % save change in demand before and after OPF
        deltas_pq = network.bus(:, [PD, QD]) - results_disp.bus(:, [PD, QD]);

        ls = 0;
        if ~isempty(loads_shed)

            % apply VCLS
            ls = 1 - sum(-results_disp.gen(results_disp.gen(:, PMIN) < 0, PG)) / sum(-results_disp.gen(results_disp.gen(:, PMIN) < 0, PMIN));

            network.bus_uvls(ismember(network.bus(:, BUS_I), results_disp.gen(results_disp.gen(:, PMIN) < 0, GEN_BUS)), i) = 1 + results_disp.gen(results_disp.gen(:, PMIN) < 0, PG) ./ network.bus(ismember(network.bus(:, BUS_I), results_disp.gen(results_disp.gen(:, PMIN) < 0, GEN_BUS)), PD);

            network.bus(ismember(network.bus(:, BUS_I), results_disp.gen(results_disp.gen(:, PMIN) < 0, GEN_BUS)), PD) = -results_disp.gen(results_disp.gen(:, PMIN) < 0, PG);
            network.bus(ismember(network.bus(:, BUS_I), results_disp.gen(results_disp.gen(:, PMIN) < 0, GEN_BUS)), QD) = -results_disp.gen(results_disp.gen(:, PMIN) < 0, QG);
            
            ind_changed = find(ismember(network.bus(:, BUS_I), results_disp.gen(results_disp.gen(:, PMIN) < 0, GEN_BUS))); % Get indices that have been changed

            for l=1:length(ind_changed) % Save bus state and over power threshold
                network.accfm_summary.busses(network.bus(ind_changed(l), BUS_I)).ls_applied(:, i) = deltas_pq(ind_changed(l), :)';
                network.accfm_summary.busses(network.bus(ind_changed(l), BUS_I)).status = LOAD_SHED;
                network.accfm_summary.busses(network.bus(ind_changed(l), BUS_I)).failure_mode(i) = VCLS;
            end

            if settings.verbose
                fprintf(repmat(' ', 1, i - k))
                fprintf(' Loads shed (%.2f%%) due to voltage collapse at buses', ls * 100);
                fprintf(repmat(' %d', 1, length(loads_shed)), results_disp.gen(loads_shed, GEN_BUS));
                fprintf('\n');
            end
        end

        results_disp.gen(results_disp.gen(:, PMIN) < 0, :) = [];

        % keep new voltages and generator outputs
        network.gen(:, [PG QG VG]) = results_disp.gen(:, [PG QG VG]);

        % run PF with the new settings to see if it converges now
        result = runpf(network, settings.mpopt);
        network.pf_count = network.pf_count + 1;

        if result.success
            % yes: proceed

            Gnode_name = get_hash();
            network.G = addnode(network.G, table({Gnode_name}, size(network.bus, 1), {''}, sum(network.bus(:, PD)), length(find(network.gen(:, GEN_STATUS) == 1)), length(find(network.branch(:, BR_STATUS) == 1)), 'VariableNames', {'Name', 'Buses', 'Type', 'Load', 'Generators', 'Lines'}));
            network.G = addedge(network.G, table({Gnode_parent Gnode_name}, {'VC'}, ls, load_initial, ls * load_initial, 'VariableNames', {'EndNodes', 'Type', 'Weight', 'Base', 'LS'}));
            Gnode_parent = Gnode_name;
        else
            % no: trip islands
            % trip island
            if settings.verbose
                fprintf(repmat(' ', 1, i - k))
                fprintf(' OPF converged but PF does not converge. Island tripped (%d buses).\n', size(network_disp.bus, 1));
            end

            network = trip_nodes(network, network.bus(:, BUS_I));
            network.bus_tripped(:, i) = 1;
            
            bus_ind = network.bus(:, BUS_I); % Get indices of busses in current island

            for l=1:length(bus_ind) % Save bus state, no other information (there are no thresholds to save, it just doesn't converge)
                network.accfm_summary.busses(bus_ind(l)).status = FAILED;
                network.accfm_summary.busses(bus_ind(l)).failure_mode(i) = VCLS;
            end

            Gnode_name = get_hash();
            network.G = addnode(network.G, table({Gnode_name}, size(network.bus, 1), {'failure'}, 0, 0, 0, 'VariableNames', {'Name', 'Buses', 'Type', 'Load', 'Generators', 'Lines'}));
            network.G = addedge(network.G, table({Gnode_parent Gnode_name}, {'OPF'}, 1, load_initial, load_initial, 'VariableNames', {'EndNodes', 'Type', 'Weight', 'Base', 'LS'}));
            Gnode_parent = Gnode_name;
        end
        
    end
end

function network = add_reference_bus( network, ignore_type )
% ADD_REFERENCE_BUS makes sure there is a reference bus in every island. If
% there is no reference bus in an island, the bus with the biggest
% generator is marked as reference bus.

    % define MATPOWER constants
    define_constants;
    
    if ~exist('ignore_type', 'var')
        ignore_type = 0;
    end

    [groups, isolated] = find_islands(network);
    
    % go through every island
    for i = 1:size(groups, 2)
        ref_bus = intersect(network.bus(groups{i}, BUS_I), network.bus(network.bus(:, BUS_TYPE) == REF, BUS_I));
        
        % if there is no reference bus in an island
        %if size(network.bus(network.bus(groups{i}, BUS_TYPE) == REF), 1) == 0

        if length(ref_bus) == 1
            %ref_bus = network.bus(network.bus(:, BUS_TYPE) == REF, BUS_I);
            %ref_bus = network.bus(groups{i}(network.bus(groups{i}, BUS_TYPE) == REF), BUS_I);
            gens = find(ismember(network.gen(:, GEN_BUS), network.bus(groups{i}, BUS_I)) & ismember(network.gen(:, GEN_BUS), ref_bus) & network.gen(:, GEN_STATUS) == 1, 1);
            
            % there is no active generator at the ref bus
            if isempty(gens)
                %network.bus(network.bus(:, BUS_TYPE) == REF, BUS_TYPE) = PQ;
                network.bus(ismember(network.bus(:, BUS_I), ref_bus), BUS_TYPE) = PQ;
                network = add_reference_bus(network, 1);
            end
        else
            network.bus(ismember(network.bus(:, BUS_I), ref_bus), BUS_TYPE) = PV;
        end
        
        ref_bus = intersect(network.bus(groups{i}, BUS_I), network.bus(network.bus(:, BUS_TYPE) == REF, BUS_I));
        
        if isempty(ref_bus)
            
            % get all active and generating buses in this island
            gens = find(ismember(network.gen(:, GEN_BUS), network.bus(groups{i}, BUS_I)) & network.gen(:, GEN_STATUS) == 1);
            gen_bus = unique(network.gen(gens, GEN_BUS));
            
            if ~ignore_type
                % only take generators at PV buses
                gen_bus = gen_bus(network.bus(ismember(network.bus(:, BUS_I), gen_bus), BUS_TYPE) == PV);
            end
            
            bus_summed_generation = accumarray(network.gen(gens, GEN_BUS), network.gen(gens, PMAX));
            bus_summed_generation = bus_summed_generation(gen_bus);
            
            % get the generator with the highest capacity
            [~, max_gen_bus] = max(bus_summed_generation);
            
            if length(max_gen_bus) == 1

                % make it reference bus
                network.bus(network.bus(:, BUS_I) == gen_bus(max_gen_bus), BUS_TYPE) = REF;

            end
        end
    end
    
    % make all isolated but active nodes reference
    inactive = network.bus(:, BUS_TYPE) == NONE;
    network.bus(isolated, BUS_TYPE) = REF;
    network.bus(inactive, BUS_TYPE) = NONE;
end