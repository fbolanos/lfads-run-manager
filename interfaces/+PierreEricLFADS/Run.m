classdef Run < LFADS.Run
    methods
        function r = Run(name, runCollection)
            % check that the param type matches
            assert(isa(runCollection.params, 'PierreEricLFADS.RunParams'), ...
                'RunCollection params must be PierreEricLFADS.RunParams');
            
            r = r@LFADS.Run(name, runCollection);
        end
        
        function seq = convertDatasetToSequenceStruct(r, dataset)
            data = dataset.loadData();
            
            switch r.params.align
                case 'GoCue'
                    totalTimeToKeep = 600; %ms
                    preGoTimeToKeep = min(data.GoCue(:) - data.CenterHeld(:));
                    postGoTimeToKeep = totalTimeToKeep - preGoTimeToKeep;
                case 'MoveOnsetOnline'
                    preGoTimeToKeep = 400;
                    postGoTimeToKeep = 500;
                otherwise
                    error('Unknown align %s', r.params.align);
            end
            
            runID = [r.nameWithParams '_' dataset.name];
            
            seq = [];
            for it = 1:data.nTrials
                
                % don't keep the ultra-short trials that reach target early
                if postGoTimeToKeep > data.TargetAcquired(it)
                    continue;
                end
                % some GoCue's are nan...
                if isnan(data.(r.params.align)(it))
                    error('GoCue is nan');
                end
                
                seq(it).runID = runID; %#ok<*AGROW>
                seq(it).trialID = data.trialId(it);
                seq(it).saveTag = dataset.saveTags;
                
                seq(it).peakSpeed2 = data.PeakSpeed2(it);
                seq(it).peakSpeed3 = data.PeakSpeed3(it);
                seq(it).rt = data.RT(it);
                
                % data is aligned to target onset
                % we'll just take time starting at target onset
                timeIndsToKeep = data.(r.params.align)(it) + (-preGoTimeToKeep:postGoTimeToKeep-1);
                [~,spikeRasterIndsToKeep] = intersect(data.spikeRasters_time, ...
                    timeIndsToKeep);
                seq(it).y = squeeze(data.spikeRasters(it, spikeRasterIndsToKeep, ...
                    :))';
                seq(it).T = size(seq(it).y,2);
                if seq(it).T == 0
                    error('Issue with data in spike raster')
                end
                
                % store down info about target name
                seq(it).targetDirectionName = data.targetDirectionName{it};
                
                % store down some hand kinematics
                x=horzcat(data.handKinematics{it,:});
                [~,handKinematicsIndsToKeep] = intersect(data.handKinematics_time{it}, ...
                    timeIndsToKeep);
                seq(it).handKinematics = x(handKinematicsIndsToKeep,:)';
            end
            
            seq(1).params.dtMS = 1;
            seq(1).params.runID = runID;
            seq(1).subject = dataset.subject;
            seq(1).date = dataset.datenum;
            
            nTrialsKeep = r.params.nTrialsKeep;
            if numel(seq) > nTrialsKeep
                seq = seq(1:nTrialsKeep);
            end
        end
        
        function [seqData, alignMatrices, trainInds, validInds] = prepareSequenceDataForLFADS(r, seqData)
            % tally up the total number of channels across all datasets
            num_channels = 0;
            
            % split each struct by condition
            for nd = 1:r.nDatasets
                datasetInfo(nd).seq = seqData{nd};
                [c,~,ic] = unique({datasetInfo(nd).seq.targetDirectionName});
                if nd==1
                    % store all the condition names
                    conditions = c; 
                    % figure out what is the minimum number of trials for each
                    % day
                    for ncond = 1:numel(c)
                        min_trials_per_condition(ncond) = sum(ic==ncond);
                    end
                else
                    if ~numel(c)==numel(conditions) || ~isequal(conditions, c)
                        error('conditions dont match between days');
                    end

                    % store down the minimum number of trials per condition
                    for ncond = 1:numel(c)
                        min_trials_per_condition(ncond) = ...
                            min(min_trials_per_condition(ncond), sum(ic==ncond));
                    end

                end
                % we are going to make a big array that spans all days. 
                % store down the indices for this day
                this_day_num_channels = size(datasetInfo(nd).seq(1).y,1);
                datasetInfo(nd).this_day_inds = num_channels + (1 : this_day_num_channels);
                num_channels = num_channels + this_day_num_channels;

            end

            % what is the minimum number of trials over all conditions, all days
            min_trials_across_conditions = min(min_trials_per_condition);

            % we are going to make a matrix that is 
            %       num_channels x (time_per_trial x total_num_trials)
            bin_size = 50;
            time_per_trial = floor(size(datasetInfo(1).seq(1).y, 2) / ...
                                   bin_size);
            if r.params.pcTrialAvg
                all_data = zeros(num_channels, time_per_trial * numel(c), ...
                                 'single');
            else
                all_data = zeros(num_channels, ...
                                 time_per_trial * min_trials_across_conditions * numel(c), ...
                                 'single');
            end

            % fill up the data matrix with binned data
            trainInds = cellvec(numel(datasetInfo));
            validInds = cellvec(numel(datasetInfo));
            for nd = 1:numel(datasetInfo)
                [c,~,ic] = ...
                    unique({datasetInfo(nd).seq.targetDirectionName});

                % start at the zero time point for each day
                data_time_ind = 0;
                for ncond = 1:numel(c)
                    trials_to_use_this_condition = find(ic==ncond);
                    for nt = 1:min_trials_across_conditions %numel(trials_to_use_this_condition)
                        trial = ...
                            datasetInfo(nd).seq(trials_to_use_this_condition(nt));
                        tmp = reshape(trial.y', ...
                                      [], time_per_trial, size(trial.y,1));
                        binned_data= squeeze(sum(tmp))';


                        % put the data in the big matrix
                        if r.params.pcTrialAvg
                            all_data(datasetInfo(nd).this_day_inds, data_time_ind ...
                                     + (1:time_per_trial)) = ...
                                all_data(datasetInfo(nd).this_day_inds, data_time_ind ...
                                         + (1:time_per_trial)) ...
                                + binned_data;
                        else
                            all_data(datasetInfo(nd).this_day_inds, data_time_ind ...
                                     + (1:time_per_trial)) = binned_data;
                            data_time_ind = data_time_ind + time_per_trial;
                        end
                    end % trials
                    if r.params.pcTrialAvg
                        data_time_ind = data_time_ind + time_per_trial;
                    end
                end % conditions

                % we also need to define some training and test indices
                vis = 1:4:numel(datasetInfo(nd).seq);
                tis = setdiff(1:numel(datasetInfo(nd).seq), vis);
                validInds{nd} = vis;
                trainInds{nd} = tis;
            end

            % divide data by number of trials
            if r.params.pcTrialAvg
                all_data = all_data / min_trials_across_conditions;
            end

            % apply PCA
            co = pca(all_data');
            keep_pcs = co(:,1:r.params.pcsKeep);

            % project all data into pca space
            dim_reduced_data = keep_pcs' * all_data;

            % get a mapping from each day to the lowD space
            for nd = 1:numel(datasetInfo)
                this_day_data = all_data(datasetInfo(nd).this_day_inds, :);

                datasetInfo(nd).alignment_matrix_cxf = (this_day_data' \ dim_reduced_data');
            end


            check_projections = true;
            % look at the low-D projection across conditions
            if check_projections

                projections=struct;
                % need some colors
                clrs = TrialDataUtilities.Color.hslmap(numel(c));
        %         clrs = cubehelix(numel(c), [0.5,-1.5,1,1], [0.2,0.8]);
                for nd = 1:r.nDatasets
                    figure(nd); clf;
                    [c,~,ic] = ...
                        unique({datasetInfo(nd).seq.targetDirectionName});

                    % start at the zero time point for each day
%                     data_time_ind = 0;
                    for ncond = 1:numel(c)
                        for npc = 1:4
                            projections(ncond,npc).proj = [];
                        end
                        trials_to_use_this_condition = find(ic == ncond, ...
                                                            min_trials_per_condition(ncond));
                        % project the trial into the latent space
                        for nt = 1:numel(trials_to_use_this_condition)
                            trial = ...
                                datasetInfo(nd) ...
                                .seq(trials_to_use_this_condition(nt));
                            tmp = reshape(trial.y', ...
                                          [], time_per_trial, size(trial.y,1));
                            binned_data= squeeze(sum(tmp))';
                            m = datasetInfo(nd).alignment_matrix_cxf;
                            proj = m' * binned_data;
                            for npc = 1:4
                                projections(ncond,npc).proj(nt,:) = proj(npc,:);
                            end
                        end %trials

                        for npc = 1:4
                            subplot(2,2,npc)
                            axis('tight');
                            m=mean(projections(ncond,npc).proj);
                            s=std(projections(ncond,npc).proj)/ ...
                              sqrt(size(projections(ncond,npc).proj,1));
        %                     h=errorbar(m,s);
                            tvec = lindelta(0, bin_size, numel(m));
                            TrialDataUtilities.Plotting.errorshade(tvec, m, s, clrs(ncond, :));
                            xlabel('Time bins');
                            hold on;
        %                     set(h,'color',clrs(ncond,:));
                            box off;
                            title(sprintf('PC %d', npc));
        %                     AutoAxis.replace();
                        end %pcs

                    end %conditions

%                     if collections(ncoll).do_trial_averaging
%                          fnout = 'trial_avg';
%                     else
%                          fnout = 'single_trial';
%                     end
%                     fnout = sprintf('%s_day%i', fnout, nd);
        %             print('-dpdf',['/tmp/multiday/alignment/' fnout]);
                end %days
            end

            %                    subplot(2,2,npc)
            %                    h=plot(proj(npc,:));
            %                    hold on;
            %                    set(h, 'color', clrs(ncond,:));

            % prepare for call to seq_to_lfads
            seqData = {datasetInfo.seq};
            alignMatrices = {datasetInfo.alignment_matrix_cxf};
        end
    end
    
end