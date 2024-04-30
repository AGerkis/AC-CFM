% get_constants_accfmsave.m
%
% Defines some commonly used constants that are used when saving the
% summary of an ACCFM run.
%
% Author: Aidan Gerkis
% Date: 29-04-2024

% Constants defining failure mechanisms
VCLS = 1;
UFLS = 2;
OFGS = 3;
OXL = 4;
UXL = 5;
UVLS = 6;
ULGT = 7;
OLP = 8;
OTHER = 9;

% Constants defining bus status
FAILED = 0;
OKAY = 1;
LOAD_SHED = 2;