% get_slack_gen.m
%
% A function that returns the indices of slack generators in the network.
% Taken from the accfm.m file in [1] and made a separate function for
% generic use.
%
% Inputs:
%   network: The network being analyzed, in MATPOWER case format.
%
% Outputs:
%   slack_gen: The indices of the slack generators in the network
%
% References:
%   [1]: Noebels, M., Preece, R., Panteli, M. "AC Cascading Failure Model 
%        for Resilience Analysis in Power Networks." IEEE Systems Journal (2020).
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