function Mobj = interp_POLCOMS2FVCOM(Mobj, ts, start_date, varlist)
% Use an FVCOM restart file to seed a model run with spatially varying
% versions of otherwise constant variables (temperature and salinity only
% for the time being).
%
% function interp_POLCOMS2FVCOM(Mobj, ts, start_date, fv_restart, varlist)
%
% DESCRIPTION:
%    FVCOM does not yet support spatially varying temperature and salinity
%    inputs as initial conditions. To avoid having to run a model for a
%    long time in order for temperature and salinity to settle within the
%    model from the atmospheric and boundary forcing, we can use a restart
%    file to cheat. For this, we need temperature and salinity
%    (potentially other variables too) interpolated onto the unstructured
%    grid. The interpolated data can then be written out with
%    write_FVCOM_restart.m.
%
% INPUT:
%   Mobj        = MATLAB mesh structure which must contain:
%                   - Mobj.siglayz - sigma layer depths for all model
%                   nodes.
%                   - Mobj.lon, Mobj.lat - node coordinates (long/lat).
%                   - Mobj.ts_times - time series for the POLCOMS
%                   temperature and salinity data.
%   ts          = Cell array of POLCOMS AMM NetCDF file(s) in which 4D
%   variables of temperature and salinity (called 'ETWD' and 'x1XD') exist.
%   Its/their shape should be (y, x, sigma, time).
%   start_date  = Gregorian start date array (YYYY, MM, DD, hh, mm, ss).
%   varlist     = cell array of variables to extract from the NetCDF files.
% 
% OUTPUT:
%   Mobj.restart = struct whose field names are the variables which have
%   been interpolated (e.g. Mobj.restart.ETWD for POLCOMS daily mean
%   temperature).
%
% EXAMPLE USAGE
%   interp_POLCOMS2FVCOM(Mobj, '/tmp/ts.nc', '2006-01-01 00:00:00', ...
%       {'lon', 'lat', 'ETWD', 'x1XD', 'time'})
%
% Author(s):
%   Pierre Cazenave (Plymouth Marine Laboratory)
%
% Revision history
%   2013-02-08 First version.
%   2013-05-16 Add support for parallel for-loops (not mandatory, but
%   enabled if the Parallel Computing Toolbox is available).
%   2013-06-06 Fix the vertical ordering of the POLCOMS data. POLCOMS'
%   scalar values (temperature, salinity etc.) are stored seabed to
%   surface; its depths are stored surface to seabed; FVCOM stores
%   everything surface to seabed. As such, the POLCOMS scalar values need
%   to be flipped upside down to match everything else.
%
%==========================================================================

subname = 'interp_POLCOMS2FVCOM';

global ftbverbose;
if ftbverbose
    fprintf('\nbegin : %s\n', subname)
end

% Run jobs on multiple workers if we have that functionality. Not sure if
% it's necessary, but check we have the Parallel Toolbox first.
wasOpened = false;
if license('test', 'Distrib_Computing_Toolbox')
    % We have the Parallel Computing Toolbox, so launch a bunch of workers.
    if matlabpool('size') == 0
        % Force pool to be local in case we have remote pools available.
        matlabpool open local
        wasOpened = true;
    end
end

%--------------------------------------------------------------------------
% Extract the NetCDF data specified in varlist
%--------------------------------------------------------------------------

% Data format:
% 
%   pc.ETWD.data and pc.x1XD.data are y, x, sigma, time
% 
pc = get_POLCOMS_netCDF(ts, varlist);

% Number of sigma layers.
[fn, fz] = size(Mobj.siglayz);

% Make rectangular arrays for the nearest point lookup.
[lon, lat] = meshgrid(pc.lon.data, pc.lat.data);

% Convert the current times to Modified Julian Day (this is a bit ugly).
pc.time.all = strtrim(regexp(pc.time.units, 'since', 'split'));
pc.time.datetime = strtrim(regexp(pc.time.all{end}, ' ', 'split'));
pc.time.ymd = str2double(strtrim(regexp(pc.time.datetime{1}, '-', 'split')));
pc.time.hms = str2double(strtrim(regexp(pc.time.datetime{2}, ':', 'split')));

Mobj.ts_times = greg2mjulian(...
    pc.time.ymd(1), ...
    pc.time.ymd(2), ...
    pc.time.ymd(3), ...
    pc.time.hms(1), ...
    pc.time.hms(2), ...
    pc.time.hms(3)) + (pc.time.data / 3600 / 24);

% Given our intput time (in start_date), find the nearest time
% index for the regularly gridded data.
stime = greg2mjulian(start_date(1), start_date(2), ...
    start_date(3), start_date(4), ...
    start_date(5), start_date(6));
[~, tidx] = min(abs(Mobj.ts_times - stime));

%--------------------------------------------------------------------------
% Interpolate the regularly gridded data onto the FVCOM grid (vertical grid
% first).
%--------------------------------------------------------------------------

if ftbverbose
    fprintf('%s : interpolate POLCOMS onto FVCOM''s vertical grid... ', subname)
end

% Permute the arrays to be x by y rather than y by x. Also flip the
% vertical layer dimension to make the POLCOMS data go from surface to
% seabed to match its depth data and to match how FVCOM works.
temperature = flipdim(permute(squeeze(pc.ETWD.data(:, :, :, tidx)), [2, 1, 3]), 3);
salinity = flipdim(permute(squeeze(pc.x1XD.data(:, :, :, tidx)), [2, 1, 3]), 3);
depth = permute(squeeze(pc.depth.data(:, :, :, tidx)), [2, 1, 3]);
mask = depth(:, :, end) >= 0; % land is positive.

pc.tempz = grid_vert_interp(Mobj, lon, lat, temperature, depth, mask);
pc.salz = grid_vert_interp(Mobj, lon, lat, salinity, depth, mask);

if ftbverbose
    fprintf('done.\n') 
end

%--------------------------------------------------------------------------
% Now we have vertically interpolated data, we can interpolate each sigma
% layer onto the FVCOM unstructured grid ready to write out to NetCDF.
% We'll use the triangular interpolation in MATLAB with the natural method
% (gives pretty good results, at least qualitatively).
%--------------------------------------------------------------------------

if ftbverbose
    fprintf('%s : interpolate POLCOMS onto FVCOM''s horizontal grid... ', subname)
end

fvtemp = nan(fn, fz);
fvsalt = nan(fn, fz);

tic
parfor zi = 1:fz
    % Set up the interpolation objects.
    ft = TriScatteredInterp(lon(:), lat(:), reshape(pc.tempz(:, :, zi), [], 1), 'natural');
    fs = TriScatteredInterp(lon(:), lat(:), reshape(pc.salz(:, :, zi), [], 1), 'natural');
    % Interpolate temperature and salinity onto the unstructured grid.
    fvtemp(:, zi) = ft(Mobj.lon, Mobj.lat);
    fvsalt(:, zi) = fs(Mobj.lon, Mobj.lat);
end

% Unfortunately, TriScatteredInterp won't extrapolate, returning instead
% NaNs outside the original data's extents. So, for each NaN position, find
% the nearest non-NaN value and use that instead. The order in which the
% NaN-nodes are found will determine the spatial pattern of the
% extrapolation.

% We can assume that all layers will have NaNs in the same place
% (horizontally), so just use the surface layer (1) for the identification
% of NaNs. Also store the finite values so we can find the nearest real
% value to the current NaN node and use its temperature and salinity
% values.
fvidx = 1:fn;
fvnanidx = fvidx(isnan(fvtemp(:, 1)));
fvfinidx = fvidx(~isnan(fvtemp(:, 1)));

% Can't parallelise this one (easily). It shouldn't be a big part of the
% run time if your source data covers the domain sufficiently.
for ni = 1:length(fvnanidx)
    % Current position
    xx = Mobj.lon(fvnanidx(ni));
    yy = Mobj.lat(fvnanidx(ni));
    % Find the nearest non-nan temperature and salinity value.
    [~, di] = min(sqrt((Mobj.lon(fvfinidx) - xx).^2 + (Mobj.lat(fvfinidx) - yy).^2));
    % Replace the temperature and salinity values at all depths at the
    % current NaN position with the closest non-nan value.
    fvtemp(fvnanidx(ni), :) = fvtemp(fvfinidx(di), :);
    fvsalt(fvnanidx(ni), :) = fvsalt(fvfinidx(di), :);
end

if ftbverbose
    fprintf('done.\n') 
    toc
end

Mobj.restart.temp = fvtemp;
Mobj.restart.salinity = fvsalt;

% Close the MATLAB pool if we opened it.
if wasOpened
    matlabpool close
end

if ftbverbose
    fprintf('end   : %s\n', subname)
end

%% Debugging figure
%
% close all
%
% tidx = 1; % time step to plot
% ri = 85; % column index
% ci = 95; % row index
%
% % Vertical profiles
% figure
% clf
%
% % The top row shows the temperature/salinity values as plotted against
% % index (i.e. position in the array). Since POLCOMS stores the seabed
% % first, its values appear at the bottom i.e. the profile is the right way
% % up. Just to make things interesting, the depths returned from the NetCDF
% % files are stored the opposite way (surface is the first value in the
% % array). So, if you plot temperature/salinity against depth, the profile
% % is upside down.
% %
% % Thus, the vertical distribution of temperature/salinity profiles should
% % match in the top and bottom rows. The temperature/salinity data are
% % flipped in those figures (either directly in the plot command, or via the
% % flipped arrays (temperature, salinity)).
% %
% % Furthermore, the pc.*.data have the rows and columns flipped, so (ci, ri)
% % in pc.*.data and (ri, ci) in 'temperature', 'salinity' and 'depth'.
% % Needless to say, the two lines in the lower plots should overlap.
%
% subplot(2,2,1)
% plot(squeeze(pc.ETWD.data(ci, ri, :, tidx)), 1:size(depth, 3), 'rx:')
% xlabel('Temperature (^{\circ}C)')
% ylabel('Array index')
% title('Array Temperature')
%
% subplot(2,2,2)
% plot(squeeze(pc.x1XD.data(ci, ri, :, tidx)), 1:size(depth, 3), 'rx:')
% xlabel('Salinity')
% ylabel('Array index')
% title('Array Salinity')
%
% subplot(2,2,3)
% % Although POLCOMS stores its temperature values from seabed to surface,
% % the depths are stored surface to seabed. Nice. Flip the
% % temperature/salinity data accordingly.
% plot(flipud(squeeze(pc.ETWD.data(ci, ri, :, tidx))), squeeze(pc.depth.data(ci, ri, :, tidx)), 'rx-')
% hold on
% plot(squeeze(temperature(ri, ci, :)), squeeze(depth(ri, ci, :)), '.:')
% xlabel('Temperature (^{\circ}C)')
% ylabel('Depth (m)')
% title('Depth Temperature')
% legend('pc', 'temp', 'location', 'north')
% legend('boxoff')
%
% subplot(2,2,4)
% % Although POLCOMS stores its temperature values from seabed to surface,
% % the depths are stored surface to seabed. Nice. Flip the
% % temperature/salinity data accordingly.
% plot(flipud(squeeze(pc.x1XD.data(ci, ri, :, tidx))), squeeze(pc.depth.data(ci, ri, :, tidx)), 'rx-')
% hold on
% plot(squeeze(salinity(ri, ci, :)), squeeze(depth(ri, ci, :)), '.:')
% xlabel('Salinity')
% ylabel('Depth (m)')
% title('Depth Salinity')
% legend('pc', 'salt', 'location', 'north')
% legend('boxoff')
%
% % Plot the sample location
% figure
% dx = mean(diff(pc.lon.data));
% dy = mean(diff(pc.lat.data));
% z = depth(:, :, end); % water depth (bottom layer depth)
% z(mask) = 0; % clear out nonsense values
% pcolor(lon - (dx / 2), lat - (dy / 2), z)
% shading flat
% axis('equal', 'tight')
% daspect([1.5, 1, 1])
% colorbar
% caxis([-150, 0])
% hold on
% plot(lon(ri, ci), lat(ri, ci), 'ko', 'MarkerFaceColor', 'w')

