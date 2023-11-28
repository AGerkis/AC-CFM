% add_reference_bus.m
%
% A function that adds a reference bus to the network.
%
% Inputs:
%   network: The network being analyzed, in MATPOWER case format.
%   ignore_type: Any busses that should NOT be allowed to be reference busses.
%
% Outputs:
%   network: The network with a reference bus
%
% References:
%   [1]: Noebels, M., Preece, R., Panteli, M. "AC Cascading Failure Model 
%        for Resilience Analysis in Power Networks." IEEE Systems Journal (2020).
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