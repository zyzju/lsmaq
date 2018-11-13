classdef rigClass < dynamicprops
    %note: a Rig is a device or piece of equipment designed for a particular purpose
    %rigClass holds all the variables linked with the setup (Analog I/O channels, triggers etc.)
    %
    
    properties
        AItask
        AIreader
        AIlistener
        AOtask
        AOwriter
        TriggerTask
        ShutterTask
        ShutterWriter
        channelOrder
        AIrate
        AOrate
        
        stage
        isScanning = false;
    end
    
    methods
        
        %rigClass is a function that generates an object "obj" that defines extra dynamic properties
        % where is fStatus?
        
        function obj = rigClass(prop, fStatus)
            obj.AIrate = 1250000;
            obj.AOrate = 250000;
            shutterline = '/Dev5/PFI1';
            AIchans = 'Dev5/ai0:1';
            AOchans = {'Dev5/ao0:1', 'Dev4/ao0:2'};
            obj.channelOrder = {[1 2], [1 2 5]};             % assign [X,Y,Z,Blank,Phase] signals (in that order, 1-based indexing) to output channels. To assign X to the first output channel, Y to the second and blank to the third, use [1 2 4]
            stageCOMPort = 'COM10';
            stage_uSteps_um = [10 10 25];
            
            if nargin < 1
                fprintf(1, 'Starting up rig: ');
                fStatus = @(fraction, text) fprintf(1, '\b\b\b%02.0f%%', fraction*100);
            end
            
            % load NIDAQmx .NET assembly
            fStatus(0/6, 'starting up: loading DAQmx...')
            try 
                NET.addAssembly('NationalInstruments.DAQmx');
                import NationalInstruments.DAQmx.*
            catch
                error('Error loading .NET assembly! Check NIDAQmx .NET installation.')
            end
            
            % Reset DAQ boards
            fStatus(1/6, 'starting up: resetting DAQ...')
            for iDev = unique(strtok([{AIchans} AOchans], '/'))
                DaqSystem.Local.LoadDevice(iDev{1}).Reset
            end
            
            % Setting up device objects
            fStatus(1/6, 'starting up: setting up DAQ...')
            obj.AItask = NationalInstruments.DAQmx.Task;
            obj.AItask.AIChannels.CreateVoltageChannel(AIchans, '', AITerminalConfiguration.Differential,-10, 10, AIVoltageUnits.Volts);
            obj.AItask.Timing.ConfigureSampleClock('', obj.AIrate, SampleClockActiveEdge.Rising, SampleQuantityMode.ContinuousSamples, 100)
            obj.AItask.Triggers.StartTrigger.ConfigureDigitalEdgeTrigger('PFI0', DigitalEdgeStartTriggerEdge.Rising);
            %obj.AItask.ExportSignals.ExportHardwareSignal(ExportSignal.StartTrigger, 'PFI0');
            obj.AItask.Control(TaskAction.Verify);
            obj.AIreader = AnalogUnscaledReader(obj.AItask.Stream);
            
            obj.AOtask{1} = NationalInstruments.DAQmx.Task;
            obj.AOtask{1}.AOChannels.CreateVoltageChannel(AOchans{1}, '',-10, 10, AOVoltageUnits.Volts);
            obj.AOtask{1}.Stream.WriteRegenerationMode = WriteRegenerationMode.AllowRegeneration;
            obj.AOtask{1}.Timing.ConfigureSampleClock('', obj.AOrate, SampleClockActiveEdge.Rising, SampleQuantityMode.ContinuousSamples, 100)
            obj.AOtask{1}.Triggers.StartTrigger.ConfigureDigitalEdgeTrigger('PFI0', DigitalEdgeStartTriggerEdge.Rising);
            obj.AOtask{1}.ExportSignals.ExportHardwareSignal(ExportSignal.SampleClock, 'PFI7');
            obj.AOtask{1}.Control(TaskAction.Verify);
            obj.AOwriter{1} = AnalogMultiChannelWriter(obj.AOtask{1}.Stream);
            
            obj.AOtask{2} = NationalInstruments.DAQmx.Task;
            obj.AOtask{2}.AOChannels.CreateVoltageChannel(AOchans{2}, '',-10, 10, AOVoltageUnits.Volts);
            obj.AOtask{2}.Stream.WriteRegenerationMode = WriteRegenerationMode.AllowRegeneration;
            obj.AOtask{2}.Timing.ConfigureSampleClock('PFI7', obj.AOrate, SampleClockActiveEdge.Rising, SampleQuantityMode.ContinuousSamples, 100)
            obj.AOtask{2}.Triggers.StartTrigger.ConfigureDigitalEdgeTrigger('PFI0', DigitalEdgeStartTriggerEdge.Rising);
            obj.AOtask{2}.Control(TaskAction.Verify);
            obj.AOwriter{2} = AnalogMultiChannelWriter(obj.AOtask{2}.Stream);
            
            obj.ShutterTask = NationalInstruments.DAQmx.Task;
            obj.ShutterTask.DOChannels.CreateChannel(shutterline,'',ChannelLineGrouping.OneChannelForEachLine);
            obj.ShutterTask.Control(TaskAction.Verify);
            obj.ShutterWriter = DigitalSingleChannelWriter(obj.ShutterTask.Stream);
            
            obj.TriggerTask = NationalInstruments.DAQmx.Task;
            obj.TriggerTask.COChannels.CreatePulseChannelTime('/Dev5/Ctr0', '', COPulseTimeUnits.Seconds, COPulseIdleState.Low, 0, 0.1, 0.1);
            obj.TriggerTask.Control(TaskAction.Verify);
            
            fStatus(5/6, 'starting up: adding stage...');
            obj.stage = MP285(stageCOMPort, stage_uSteps_um);
            
            fStatus(1); fprintf(1, '\n');
        end
        
        function shutterClose(obj)
            % Closes shutter
            obj.ShutterWriter.WriteSingleSampleSingleLine(true, false);
        end
        
        function shutterOpen(obj)
            % Opens shutter
            obj.ShutterWriter.WriteSingleSampleSingleLine(true, true);
        end
        
        function hwTrigger(obj)
            % Launch hardware trigger
            obj.TriggerTask.Start
            obj.TriggerTask.WaitUntilDone(-1)
            obj.TriggerTask.Stop
        end
        
        function queueOutputData(obj, scannerOut)
            import NationalInstruments.DAQmx.*
            nsamples = size(scannerOut, 1);
            obj.AOtask{1}.Timing.ConfigureSampleClock('', obj.AOrate, SampleClockActiveEdge.Rising, SampleQuantityMode.ContinuousSamples, nsamples)
            obj.AOwriter{1}.WriteMultiSample(false, scannerOut(:, obj.channelOrder{1})');
            for iWriter = 2:numel(obj.AOwriter)
                obj.AOtask{iWriter}.Timing.ConfigureSampleClock('PFI7', obj.AOrate, SampleClockActiveEdge.Rising, SampleQuantityMode.ContinuousSamples, nsamples)
                obj.AOwriter{iWriter}.WriteMultiSample(false, scannerOut(:, obj.channelOrder{iWriter})');
            end
        end
        
        function setupAIlistener(obj, fun, nsamples)
            import NationalInstruments.DAQmx.*
            obj.AItask.Timing.ConfigureSampleClock('',obj.AIrate,SampleClockActiveEdge.Rising,SampleQuantityMode.ContinuousSamples,nsamples*10);
            obj.AItask.EveryNSamplesReadEventInterval = nsamples;
            obj.AIlistener = addlistener(obj.AItask, 'EveryNSamplesRead', @(~, ev) fun(obj.AIreader.ReadInt16(nsamples).int16));
        end
        
        function start(obj)
            for iTask = [obj.AOtask {obj.AItask}]
                iTask{1}.Start
            end
        end
        
        function stopAndCleanup(obj, varargin)
            % stop everything and cleanup appropriately
            obj.shutterClose;
            delete(obj.AIlistener)
            for iTask = [{obj.AItask} obj.AOtask]
                iTask{1}.Stop
            end
            obj.isScanning = false;
        end
        
    end
    
end