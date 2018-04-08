unit dcm_load;

{$mode objfpc}{$H+}

interface

uses
  {$IFNDEF UNIX} Windows, shlobj, {$ENDIF}
  ClipBrd, ExtCtrls, StdCtrls, Forms, Controls, Classes, SysUtils, dialogs, Process;


function dcm2Nifti(dcm2niixExe, dicomDir: string): string;

implementation

function seriesNum (s: string): single; //"601 myName" returns 601
begin
  result := StrToFloatDef(Copy(s, 1, pos(' ',s)-1),-1);
end;

function seriesName (s: string): string; //"601 myName" returns 'myName'
var
    delimPos: integer;
begin
  delimPos := pos(' ',s);
  if (delimPos < 1) or (delimPos >= length(s)) then exit;
  result := Copy(s, delimPos+1, maxInt);
end;

function compareSeries(List: TStringList; Index1, Index2: Integer): Integer;
var
  n1, n2: single;
begin
  n1 := seriesNum(List[Index1]);
  n2 := seriesNum(List[Index2]);
  if (n1 >= n2) then
     result := 1
  else
     result := -1;
  //result := n1 - n2;
end;

function dcmStr(s: string): string;
var
     sl: TStringList;
begin
  result := '';
  if (length(s) < 1) or (s[1] <> chr(9)) then exit;
  sl := TStringList.Create;
  sl.Delimiter := #9; //TAB
  sl.DelimitedText := s;
  if sl.Count >= 2 then begin
    result := sl[0]+' '+extractfilename(sl[1]) ;
  end else
   result := '';
  sl.Free;
end;


function dcmList(dcm2niixExe, dicomDir: string): TStringList;
//make sure to free result!
//strList := dcmList(); strList.free;
var
    hprocess: TProcess;
    sData: TStringList;
    s: string;
    x: integer;
Begin
  result := Tstringlist.Create;
  if dcm2niixExe = '' then exit;
   hProcess := TProcess.Create(nil);
   hProcess.Executable := dcm2niixExe;
   hprocess.Parameters.Add('-n');
   hprocess.Parameters.Add('-1');
   hprocess.Parameters.Add('-f');
   hprocess.Parameters.Add('%p_%t');
   hprocess.Parameters.Add(dicomDir);
   hProcess.Options := hProcess.Options + [poWaitOnExit, poUsePipes];
   hProcess.Execute;
   sData := Tstringlist.Create;
   sData.LoadFromStream(hProcess.Output);
   for x := 0 to sData.Count -1 do begin
       s := dcmStr(sData[x]);
       if (s <> '') then
           result.Add(s);
   end;
   //next: sort (optional)
   sData.Clear;
   sData.AddStrings(result);
   sData.CustomSort(@compareSeries);
   result.Clear;
   result.AddStrings(sData);
   //ClipBoard.AsText:=(sData.Text);
   //release data
   sData.Free;
   hProcess.Free;
end;

function dcmSeriesSelectForm(dcm2niixExe, dicomDir: string): string;
const
  kMaxItems = 16;
var
  PrefForm: TForm;
  rg: TRadioGroup;
  dcmStrings: TStringlist;
  OKBtn: TButton;
  w,h: integer;
label
  123;
begin
  result := '';
  dcmStrings := dcmList(dcm2niixExe, dicomDir);
  if dcmStrings.Count < 1 then goto 123; //no files
  if dcmStrings.Count = 1 then begin
    result := dcmStrings[0];//seriesNum(dcmStrings[0]);
    goto 123;
  end;
  PrefForm:=TForm.Create(nil);
  PrefForm.SetBounds(100, 100, 520, 212);
  PrefForm.Caption:='DICOM Loading '+dcm2niixExe;
  PrefForm.Position := poScreenCenter;
  PrefForm.BorderStyle := bsDialog;
  {$IFNDEF FPC}PrefForm.AutoSize := true;{$ENDIF}
  //radio group
  rg := TRadioGroup.create(PrefForm);
  rg.align := alTop;
  rg.AutoSize:=false;
  rg.parent := PrefForm;
  rg.caption := 'Select DICOM Series';
  if dcmStrings.Count > (kMaxItems) then begin
     rg.caption := rg.caption + ' (Partial Listing)';
     while (dcmStrings.Count > kMaxItems) do
           dcmStrings.Delete(dcmStrings.Count-1);
  end;
  rg.items := dcmStrings;
  rg.BorderSpacing.Around := 8;
  rg.AutoSize := true;
  rg.HandleNeeded;
  rg.GetPreferredSize(w, h);
  rg.AutoSize := false;
  rg.Align := alTop;
  rg.Height := h;
  rg.ItemIndex:=0;
  //OK button
  OkBtn:=TButton.create(PrefForm);
  OkBtn.Caption:='OK';
  OkBtn.Left := PrefForm.Width - 128;
  OkBtn.Width:= 100;
  OkBtn.Top := rg.Height+rg.Top+4;
  OkBtn.Parent:=PrefForm;
  OkBtn.ModalResult:= mrOK;
  PrefForm.Height:= OkBtn.Top + OkBtn.Height+4;
  PrefForm.ShowModal;
  result := rg.Items[rg.ItemIndex];//seriesNum(rg.Items[rg.ItemIndex]);
  FreeAndNil(PrefForm);
 123: //cleanup
  dcmStrings.Free;
end; // PrefMenuClick()

function HomeDir: string; //set path to home if not provided
{$IFDEF UNIX}
begin
   result := expandfilename('~/');
end;
{$ELSE}
var
  SpecialPath: PWideChar;
begin
  Result := '';
  SpecialPath := WideStrAlloc(MAX_PATH);
  try
    FillChar(SpecialPath^, MAX_PATH, 0);
    if SHGetSpecialFolderPathW(0, SpecialPath, CSIDL_PERSONAL, False) then
      Result := SpecialPath+pathdelim;
  finally
    StrDispose(SpecialPath);
  end;
end;
{$ENDIF}

function findNiiFile(baseName: string): string;
//if baseName '~/d/img.nii' does not exist but '~/d/img_e1.nii' does
var
  searchResult : tsearchrec;
begin
  result := basename;
  if FindFirst(changefileext(baseName, '*.nii'), faAnyFile, searchResult) = 0 then begin
     result := ExtractFilePath(basename) + searchResult.Name;
     FindClose(searchResult);
  end;
end;

function dcm2niiSeries(dcm2niixExe, dicomDir, series_name: string): string;
const
  kdcmLoadTempStr = 'MRIcroGLTemp_';
var
    hprocess: TProcess;
    series: single;
    //isTemp: boolean = false;
Begin
  result := '';
  //showmessage(dcm2niixExe+'>'+dicomDir+' >> '+ HomeDir);
  if dcm2niixExe = '' then exit;
  series := seriesNum(series_name);
  if series < 1 then exit;
  result := seriesName(series_name);
  if result = '' then exit;
  result := HomeDir+ result+'.nii';
  if (fileexists(result)) then begin //if we do over-write, make sure temp in filename
     if MessageDlg('Overwrite image '+result+'?',mtInformation,[mbAbort, mbOK],0) = mrAbort then
        exit;
  end;
   hProcess := TProcess.Create(nil);
   hProcess.Executable := dcm2niixExe;
   hprocess.Parameters.Add('-n');
   hprocess.Parameters.Add(format('%g', [series]));
   hprocess.Parameters.Add('-f');
   //if isTemp then
   //   hprocess.Parameters.Add(kdcmLoadTempStr+'%p_%t')
   //else
   hprocess.Parameters.Add('%p_%t');
   hprocess.Parameters.Add('-b');
   hprocess.Parameters.Add('n');
   hprocess.Parameters.Add('-z');
   hprocess.Parameters.Add('n');
   hprocess.Parameters.Add('-o');
   hprocess.Parameters.Add(HomeDir);
   hprocess.Parameters.Add(dicomDir);
   hProcess.Options := hProcess.Options + [poWaitOnExit, poUsePipes];
   hProcess.Execute;
   hProcess.Free;
   if fileexists(result) then exit;
   result := findNiiFile(result); //error handling for multiple echo or coil images

end;

function dcm2Nifti(dcm2niixExe, dicomDir: string): string;
begin
  result := '';
  if dcm2niixExe = '' then exit;
  result := dcmSeriesSelectForm(dcm2niixExe, dicomDir);
  if result = '' then exit;
  result := dcm2niiSeries(dcm2niixExe, dicomDir, result);
  //showmessage(dicomDir);
end;

end.
