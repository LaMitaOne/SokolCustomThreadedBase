program SampleProject;

uses
  Vcl.Forms,
  UnitSample in 'UnitSample.pas' {FormSample},
  uSokolCustomThreadedBase in 'uSokolCustomThreadedBase.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TFormSample, FormSample);
  Application.Run;
end.
