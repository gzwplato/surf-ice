program tracktion;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
  {$ENDIF}{$ENDIF}
  Classes, SysUtils, CustApp, nifti_loader, define_types, matmath, math,
tracktion_tracks, DateUtils;

const
  kMaxWayPoint = 8; //we can store 8 independent waypoint maps with 1-byte per pixel
type
  TTrackingPrefs = record
    mskName, v1Name, outName: string;
    waypointName: array [0..(kMaxWayPoint-1)] of string;
    simplifyToleranceMM, simplifyMinLengthMM, mskThresh, stepSize, maxAngleDeg, redundancyToleranceMM : single;
    minLength, smooth, seedsPerVoxel: integer;
  end;
  { TFiberQuant }

  TFiberQuant = class(TCustomApplication)
  protected
    procedure DoRun; override;
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
    procedure WriteHelp(var p: TTrackingPrefs); virtual;
  end;


procedure showMsg(msg: string);
begin
  writeln(msg);
end;

const
  mxTrkLen = 512;


type
  TNewTrack = record
    len: integer;
    dir: TPoint3f;
    pts: array [0..mxTrkLen] of TPoint3f;
  end;

procedure showMat(vox2mmMat: TMat44);
begin
     showmsg(format('v2mm= [%g %g %g %g; %g %g %g %g; %g %g %g %g; 0 0 0 1]',
        [vox2mmMat[1,1],vox2mmMat[1,2],vox2mmMat[1,3],vox2mmMat[1,4],
        vox2mmMat[2,1],vox2mmMat[2,2],vox2mmMat[2,3],vox2mmMat[2,4],
        vox2mmMat[3,1],vox2mmMat[3,2],vox2mmMat[3,3],vox2mmMat[3,4] ]) );
end;

function vox2mm(Pt: TPoint3f; vox2mmMat: TMat44) : TPoint3f; inline;
begin
     result.X := Pt.X*vox2mmMat[1,1] + Pt.Y*vox2mmMat[1,2] + Pt.Z*vox2mmMat[1,3] + vox2mmMat[1,4];
     result.Y := Pt.X*vox2mmMat[2,1] + Pt.Y*vox2mmMat[2,2] + Pt.Z*vox2mmMat[2,3] + vox2mmMat[2,4];
     result.Z := Pt.X*vox2mmMat[3,1] + Pt.Y*vox2mmMat[3,2] + Pt.Z*vox2mmMat[3,3] + vox2mmMat[3,4];
end;

function FindImgVal(var filename: string; out volume: integer): boolean;
// "/dir/img" will return "/dir/img.nii"; "img.nii,3" will return 3 as volume number
var
   p,n,x, basename: string;
   idx: integer;
begin
  result := true;
  basename := filename;
  volume := 0;
  idx := LastDelimiter(',',filename);
  if (idx > 0) and (idx < length(filename)) then begin
     x := copy(filename, idx+1, length(filename));
     volume := StrToIntDef(x,-1);
     if volume < 0 then
        showmsg('Expected positive integer after comma: '+filename)
     else
         filename := copy(filename, 1, idx-1);
     //if not file
     //showmsg(format('"%s" %d', [filename, volume]) );
  end;
  //FilenameParts (basename, pth,n, x);
  if fileexists(filename) then exit;
  FilenameParts (filename, p,n, x);
  filename := p + n + '.nii.gz';
  if fileexists(filename) then exit;
  filename := p + n + '.nii';
  if fileexists(filename) then exit;
  showmsg('Unable to find images "'+basename+'"');
  result := false;
end; //FindImgVol

procedure MatOK(var vox2mmMat: TMat44);
var
  Pt0,Pt1: TPoint3f;
begin
     Pt0 := vox2mm(ptf(0,0,0),vox2mmMat);
     Pt1 := vox2mm(ptf(1,1,1),vox2mmMat);
     vectorSubtract(Pt0,Pt1);
     if (Pt0.X <> 0) and (Pt0.Y <> 0) and (Pt0.Z <> 0) then exit;
     showmsg('NIfTI s-form does not make sense: result will be in voxels not mm');
     showMat(vox2mmMat);
     vox2mmMat := matrixSet(1,0,0,0, 0,1,0,0, 0,0,1,0);
end;

function track (var p: TTrackingPrefs): boolean;
//http://individual.utoronto.ca/ktaylor/DTIstudio_mori2006.pdf
// http://www.ncbi.nlm.nih.gov/pubmed/16413083
//Specifically section 2.3 Fiber Tracking
const
  (*mskName = '/Users/rorden/Documents/pas/surfice/FA.nii.gz';
  v1Name = '/Users/rorden/Documents/pas/surfice/V1.nii.gz';
  simplifyToleranceMM = 0.2;
  simplifyMinLengthMM = 12;
  mskThresh : single = 0.15;   //minFA 0.15
  stepSize : single = 0.5;
  maxAngleDeg : single = 45;
  minLength = 10;  *)
  kChunkSize = 16384;

label
  666;
var
  startTime: TDateTime;
   msk, v1: TNIFTI;
   waypointBits: byte;
   mskMap, waypointMap :TImgRaw;
   vox2mmMat: TMat44;
   seedOrigin : TPoint3f;
   waypointName: string;
   TrkPos, vx, i, j, x,y,z, sliceVox, volVox, seed, waypointVal: integer;
   YMap, ZMap: TInts;
   negTrk, posTrk: TNewTrack;
   minCosine: single;
   Trk: TTrack;
function XYZ2vox(xi,yi,zi: integer): integer; inline;
//convert from 3D coordinates to 1D array
begin
     result := xi + YMap[yi] + ZMap[zi];
end;
{$IFDEF LINEAR_INTERPOLATE}
function getVoxelIntensity(Pt: TPoint3f; vol: integer): single;
//http://paulbourke.net/miscellaneous/interpolation/
var
  PtLo, PtHi: TPoint3i;
  FracLo, FracHi: TPoint3f;
  volOffset : integer;
//convert from 3D coordinates to 1D array
begin
     //http://paulbourke.net/miscellaneous/interpolation/
     PtLo:= pti(trunc(Pt.x), trunc(Pt.y), trunc(Pt.z));
     PtHi := vectorAdd(PtLo, 1);
     FracHi.X := Pt.X - PtLo.X;
     FracHi.Y := Pt.Y - PtLo.Y;
     FracHi.Z := Pt.Z - PtLo.Z;
     FracLo := ptf(1,1,1);
     vectorSubtract(FracLo, FracHi);
     volOffset := vol*volVox;
     result := v1.img[XYZ2vox(PtLo.X, PtLo.Y, PtLo.Z)+volOffset] * FracLo.X *FracLo.Y * FracLo.Z //000
             + v1.img[XYZ2vox(PtHi.X, PtLo.Y, PtLo.Z)+volOffset] * FracHi.X *FracLo.Y * FracLo.Z //100
             + v1.img[XYZ2vox(PtLo.X, PtHi.Y, PtLo.Z)+volOffset] * FracLo.X *FracHi.Y * FracLo.Z //010
             + v1.img[XYZ2vox(PtLo.X, PtLo.Y, PtHi.Z)+volOffset] * FracLo.X *FracLo.Y * FracHi.Z //001
             + v1.img[XYZ2vox(PtHi.X, PtLo.Y, PtHi.Z)+volOffset] * FracHi.X *FracLo.Y * FracHi.Z //101
             + v1.img[XYZ2vox(PtLo.X, PtHi.Y, PtHi.Z)+volOffset] * FracLo.X *FracHi.Y * FracHi.Z //011
             + v1.img[XYZ2vox(PtHi.X, PtHi.Y, PtLo.Z)+volOffset] * FracHi.X *FracHi.Y * FracLo.Z //110
             + v1.img[XYZ2vox(PtHi.X, PtHi.Y, PtHi.Z)+volOffset] * FracHi.X *FracHi.Y * FracHi.Z //111
             ;
end;
{$ELSE}
function getVoxelIntensity(Pt: TPoint3f; vol: integer): single;
// nearest neighbor
var
  PtLo: TPoint3i;
begin
     PtLo:= pti(trunc(Pt.x), trunc(Pt.y), trunc(Pt.z));
     result := v1.img[XYZ2vox(PtLo.X, PtLo.Y, PtLo.Z)+vol*volVox]; //000
end;
{$ENDIF}
function getDir(Pt: TPoint3f): TPoint3f; inline;
var
  iPt: TPoint3i;
//convert from 3D coordinates to 1D array
begin
     iPt:= pti(round(Pt.x), round(Pt.y), round(Pt.z));
     if mskMap[XYZ2vox(iPt.X, iPt.Y, iPt.Z)] <> 1 then begin //FA out of range
        result := ptf(10,10,10);
        exit;
     end;
     result.X := getVoxelIntensity(Pt, 0);
     result.Y := getVoxelIntensity(Pt, 1);
     result.Z := getVoxelIntensity(Pt, 2);
     vectorNormalize(result);
end;

procedure AddSteps(var newTrk: TNewTrack; seedStart: TPoint3f; reverseDir: boolean);
var
   pos, dir: TPoint3f;
   cosine: single;
begin
     newTrk.len := 0;
     pos := seedStart;
     newTrk.dir := getDir(SeedStart);
     if reverseDir then
        newTrk.dir := vectorMult(newTrk.dir,-1);
     while (newTrk.dir.X < 5) and (newTrk.len < mxTrkLen) do begin
           newTrk.pts[newTrk.len] := pos; //add previous point
           newTrk.len := newTrk.len + 1;
           vectorAdd(pos, vectorMult(newTrk.dir, p.stepSize)); //move in new direction by step size
           dir := getDir(pos);
           cosine := vectorDot(dir, newTrk.dir);
           if ( abs(cosine) < minCosine) then exit; //if steep angle: fiber ends
           if (cosine < 0) and (dir.X < 5) then
              dir := vectorMult(dir,-1);
           newTrk.dir := dir;
     end;
end; //AddStep

procedure AddFiber;
var
   newVtx, newItems, outPos, i, iStop : integer;
   VtxBits : byte;
   Pt : TPoint3f;
begin
     newVtx := 0;
     if (posTrk.len > 1) then
        newVtx := newVtx + posTrk.len;
     if (negTrk.len > 1) then
        newVtx := newVtx + negTrk.len;
     if (posTrk.len > 1) and (negTrk.len > 1) then
       newVtx := newVtx - 1; //1st vertex shared by both
     if (newVtx < 2) then exit;
     if (waypointBits > 0) then begin
        VtxBits := 0;
        if posTrk.len > 1 then
           for i := 0 to (posTrk.len -1) do
               VtxBits := VtxBits or waypointMap[XYZ2vox(round(posTrk.pts[i].X), round(posTrk.pts[i].Y), round(posTrk.pts[i].Z) )];
        if negTrk.len > 1 then
           for i := 0 to (negTrk.len -1) do
               VtxBits := VtxBits or waypointMap[XYZ2vox(round(negTrk.pts[i].X), round(negTrk.pts[i].Y), round(negTrk.pts[i].Z) )];
        if VtxBits <> waypointBits then exit;
     end;
     newItems := 1 + (newVtx * 3); //each fiber: one element encoding number of vertices plus 3 values (X,Y,Z) for each vertex
     if length(Trk.tracks) < (TrkPos + newItems) then
        setlength(Trk.tracks, TrkPos + newItems + kChunkSize); //large ChunkSize reduces the frequency of the slow memory re-allocation
     Trk.tracks[TrkPos] := asSingle(newVtx);
     outPos := 1;
     if (negTrk.len > 1) then begin
       if (posTrk.len > 1) then
          iStop := 1 //do not save seed node if it is shared between positive and negative
       else
           iStop := 0;
       for i := (negTrk.len -1) downto iStop do begin
             Pt := negTrk.pts[i];
             Pt := vox2mm(Pt, vox2mmMat);
           Trk.tracks[TrkPos+outPos] := Pt.X; outPos := outPos + 1;
           Trk.tracks[TrkPos+outPos] := Pt.Y; outPos := outPos + 1;
           Trk.tracks[TrkPos+outPos] := Pt.Z; outPos := outPos + 1;
       end;
     end;
     if (posTrk.len > 1) then begin
       for i := 0 to (posTrk.len -1) do begin
           Pt := posTrk.pts[i];
           Pt := vox2mm(Pt, vox2mmMat);
           Trk.tracks[TrkPos+outPos] := Pt.X; outPos := outPos + 1;
           Trk.tracks[TrkPos+outPos] := Pt.Y; outPos := outPos + 1;
           Trk.tracks[TrkPos+outPos] := Pt.Z; outPos := outPos + 1;
       end;
     end;
     TrkPos := TrkPos + newItems;
     Trk.n_count := Trk.n_count + 1;
end; //AddFiber()
begin
     result := false;
     startTime := Now;
     msk := TNIFTI.Create;
     v1 := TNIFTI.Create;
     Trk := TTrack.Create;
     TrkPos := 0; //empty TRK file
     minCosine := cos(DegToRad(p.maxAngleDeg));
     if (p.seedsPerVoxel < 1) or (p.seedsPerVoxel > 9) then begin
        showmsg('seedsPerVoxel must be between 1 and 9');
        p.seedsPerVoxel := 1;
     end;
     //load mask
     if not msk.LoadFromFile(p.mskName, kNiftiSmoothNone) then begin
        showmsg(format('Unable to load mask named "%s"', [p.mskName]));
        goto 666;
     end;
     vox2mmMat := msk.mat;
     MatOK(vox2mmMat);

     if (msk.minInten = msk.maxInten) then begin
        showmsg('Error: No variability in mask '+ p.mskName);
        goto 666;
     end;
     if specialsingle(p.mskThresh) then
        p.mskThresh := (0.5 * (msk.maxInten - msk.minInten))+ msk.minInten;
     if (p.mskThresh < msk.minInten) or (p.mskThresh > msk.maxInten) then begin
        p.mskThresh := (0.5 * (msk.maxInten - msk.minInten))+ msk.minInten;
        showmsg(format('Requested threshold make sense (image range %g..%g). Using %g.',[msk.minInten, msk.maxInten, p.mskThresh]));
        goto 666;
     end;
     //load V1
     v1.isLoad4D:= true;
     if not v1.LoadFromFile(p.v1Name, kNiftiSmoothNone) then begin
        showmsg(format('Unable to load V1 named "%s"', [p.v1Name]));
        goto 666;
     end;
     volVox := length(msk.img);
     if (volVox *3 ) <> length(v1.img) then begin
        showmsg(format('Error: v1 should have 3 times the voxels as the mask (voxels %d  vs %d). Check v1 has 3 volumes and image dimensions match', [length(v1.img), length(msk.img)] ));
        goto 666;
     end;
     //make arrays for converting from 3D coordinates to 1D array
     sliceVox := msk.hdr.dim[1] * msk.hdr.dim[2]; //voxels per slice
     setlength(YMap, msk.hdr.dim[2]);
     for i := 0 to (msk.hdr.dim[2]-1) do
         YMap[i] := i * msk.hdr.dim[1];
     setlength(ZMap, msk.hdr.dim[3]);
     for i := 0 to (msk.hdr.dim[3]-1) do
         ZMap[i] := i * sliceVox;
     //set byte mask: vs msk.img this is less memory and faster (int not float)
     setlength(mskMap, volVox);
     for i := 0 to (volVox -1) do
         mskMap[i] := 0;
     for i := 0 to (volVox -1) do
         if (msk.img[i] > p.mskThresh) then
            mskMap[i] := 1;
     msk.Close;
     //next: we will zero the edge so we do not need to do bounds checking
     for i := 0 to (sliceVox -1) do begin
         mskMap[i] := 0; //bottom slice
         mskMap[volVox-1-i] := 0; //top slice
     end;
     //erase left and right edges
     for z := 0 to (msk.hdr.dim[3]-1) do //for each slice
         for y := 0 to (msk.hdr.dim[2]-1) do begin //for each row
             mskMap[XYZ2vox(0,y,z)] := 0;
             mskMap[XYZ2vox(msk.hdr.dim[1]-1,y,z)] := 0;
         end;
     //erase anterior and posterior edges
     for z := 0 to (msk.hdr.dim[3]-1) do //for each slice
         for x := 0 to (msk.hdr.dim[1]-1) do begin //for each column
             mskMap[XYZ2vox(x,0,z)] := 0;
             mskMap[XYZ2vox(x,msk.hdr.dim[2]-1,z)] := 0;
         end;
     //check that voxels survive for mapping
     vx := 0;
     for i := 0 to (volVox -1) do
         if (mskMap[i] = 1) then
            vx := vx + 1;
     if (vx < 1) then begin //since we already have checked mskThresh, we only get this error if the only voxels surviving threshold were on the outer boundary
        showmsg(format(' No voxels have FA above %.3f',[p.mskThresh]));
        goto 666;
     end;
     showmsg(format(' %d voxels have FA below %.3f',[vx, p.mskThresh]));
     //setup waypoints
     setlength(waypointMap, volVox);
     fillchar(waypointMap[0], volVox, 0);
     waypointBits := 0;
     for i := 0 to (kMaxWayPoint-1) do begin
         if length(p.waypointName[i]) < 1 then continue;
         waypointName := p.waypointName[i];
         if not FindImgVal(waypointName, waypointVal) then continue;
         if not msk.LoadFromFile(waypointName, kNiftiSmoothNone) then begin
            showmsg(format('Unable to load mask named "%s"', [waypointName]));
            goto 666;
         end;
         if volVox <> length(msk.img) then begin
            showmsg(format('Error: waypoint image should have same dimensions as other images (voxels %d  vs %d): %s', [volVox, length(msk.img), p.waypointName[i]] ));
            goto 666;
         end;
         vx := 0;
         x := 1 shl i;
         if waypointVal <> 0 then
            for j := 0 to (volVox -1) do
                if msk.img[j] = waypointVal then begin
                   waypointMap[j] := waypointMap[j] + x;
                   vx := vx + 1;
                end;
         if waypointVal = 0 then
            for j := 0 to (volVox -1) do
                if msk.img[j] <> 0 then begin
                   waypointMap[j] := waypointMap[j] + x;
                   vx := vx + 1;
                end;

         if vx > 0 then begin
            waypointBits := waypointBits + (1 shl i); //1,2,4,8,16
            showmsg(format('%s has %d voxels',[p.waypointName[i], vx]));
         end else
             showmsg(format('Warning: %s has NO surviving voxels. Intensity range %g..%g',[p.waypointName[i], msk.minInten, msk.maxInten ]));

     end;
     if waypointBits = 0 then
        setlength(waypointMap, 0);
     //free the mask image, as we use mskMap
     msk.Close;
     //map fibers
     negTrk.len := 0;
     posTrk.len := 0;
     RandSeed := 123; //make sure "random" seed placement is precisely repeated across runs
     for z := 1 to (msk.hdr.dim[3]-2) do //for each slice [except edge]
         for y := 1 to (msk.hdr.dim[2]-2) do //for each row [except edge]
             for x := 1 to (msk.hdr.dim[1]-2) do begin //for each column [except edge]
                 vx := XYZ2vox(x,y,z);
                 if (mskMap[vx] = 1) then begin
                    for seed := 1 to p.seedsPerVoxel do begin
                        if p.seedsPerVoxel = 1 then
                           seedOrigin := ptf(x,y,z)
                        else
                            seedOrigin := ptf(x+0.5-random ,y+0.5-random ,z+0.5-random);
                      AddSteps(posTrk, seedOrigin, false);
                      AddSteps(negTrk, seedOrigin, true);
                      if ((posTrk.len+negTrk.len) >= p.minLength) then
                         AddFiber;
                    end; //for each seed
                 end; //FA above threshold: create new fiber
             end; //for x
    setlength(Trk.tracks, TrkPos);
    //simplify
    if length(Trk.tracks) < 1 then begin
      showmsg('No fibers found');
      goto 666;
    end;
    if p.smooth = 1 then
       Trk.Smooth;
    Trk.SimplifyRemoveRedundant(p.redundancyToleranceMM);
    Trk.SimplifyMM(p.simplifyToleranceMM, p.simplifyMinLengthMM);
    if p.smooth = 1 then //run a second time after simplification
       Trk.Smooth;
    //save data
    Trk.Save(p.outName);
    showmsg(format('Fiber tracking completed (%dms)', [ MilliSecondsBetween(Now, startTime)]));
    result := true;
666:
     msk.Free;
     v1.Free;
     Trk.Close;
end;


constructor TFiberQuant.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  StopOnException:=True;
end;

destructor TFiberQuant.Destroy;
begin
  inherited Destroy;
end;

procedure TFiberQuant.WriteHelp (var p: TTrackingPrefs);
var
   xname: string;
begin
  xname := extractfilename(ExeName);
  showmsg('Tracktion by Chris Rorden version 19Sept2016');
  showmsg('Usage: '+ xname+ ' [options] basename');
  showmsg(' Requires dtifit V1 FA images (basename_V1.nii.gz, basename_FA.nii.gz)');
  showmsg('Options');
  showmsg(format(' -a maximum angle bend (degrees, default %.3g)', [p.maxAngleDeg]));
  showmsg(' -h show help');
  showmsg(format(' -l minimum length (mm, default %.3g)', [p.simplifyMinLengthMM]));
  showmsg(' -o output name (.bfloat, .bfloat.gz or .vtk; default "inputName.vtk")');
  showmsg(format(' -s simplification tolerance (mm, default %.3g)', [p.simplifyToleranceMM]));
  showmsg(format(' -t fa threshold (default %.3g)', [p.mskThresh]));
  showmsg(format(' -w waypoint name (up to %d; default: none)',[kMaxWayPoint]));
  showmsg(format(' -1 smooth (0=not, 1=yes, default %d)', [p.smooth]));
  showmsg(format(' -2 stepsize (voxels, voxels %.3g)', [p.stepSize]));
  showmsg(format(' -3 minimum steps (voxels, default %d)', [p.minLength]));
  showmsg(format(' -4 redundant fiber removal threshold (mm, default %g)', [p.redundancyToleranceMM]));
  showmsg(format(' -5 seeds per voxel (default %d)', [p.seedsPerVoxel]));
  showmsg('Examples');
  {$IFDEF UNIX}
   showmsg(' '+xname+' -t 0.2 -o "~/out/fibers.vtk" "~/img_V1.nii.gz"');
   showmsg(' '+xname+' -w BA44.nii -w BA44.nii "~/img_V1.nii"');
  {$ELSE}
   to do showmsg(' '+xname+' -t 1 -o "c:\out dir\shrunk.vtk" "c:\in dir in.vtk"');
  {$ENDIF}
end;

function FindV1FA(pth, n, x: string; var p: TTrackingPrefs; reportError: integer): boolean;
begin
     result := true;
     p.v1Name := pth+n+'_V1'+x;
     p.mskName := pth+n+'_FA'+x;
     if fileexists(p.v1Name) and fileexists(p.mskName) then exit;
     result := false;
     if reportError <> 0 then
        showmsg(format('Unable to find "%s" and "%s"',[p.v1Name, p.mskName]));
end;//FindV1FA()

function FindNiiFiles(var basename: string; var p: TTrackingPrefs): boolean;
var
   pth,n,x: string;
   i: integer;
begin
  result := true;
  FilenameParts (basename, pth,n, x);
  for i := 0 to 1 do begin
    x := '.nii.gz';
    if FindV1FA(pth, n, x, p, i) then exit;
    x := '.nii';
    if FindV1FA(pth, n, x, p, i) then exit;
    if length(n) > 3 then begin //i_FA i_V1
       SetLength(n, Length(n) - 3);
       if FindV1FA(pth, n, x, p, i) then exit;
       x := '.nii.gz';
       if FindV1FA(pth, n, x, p, i) then exit;
    end;
  end;
  result := false;
end; //FindNiiFiles()

procedure TFiberQuant.DoRun;
var
  p : TTrackingPrefs = (mskName: ''; v1Name: ''; outName: '';
    waypointName: ('','','','',  '','','','');
    simplifyToleranceMM: 0.2;
    simplifyMinLengthMM: 12;
    mskThresh: 0.15;
    stepSize: 0.5;
    maxAngleDeg: 45;
    redundancyToleranceMM: 0;
    minLength: 1;
    smooth: 1;
    seedsPerVoxel: 1);
  basename: string;
  i: integer;
  nWaypoint: integer = 0;
begin
  // parse parameters
  basename := 'test.nii,7';
  //FindImg(basename, nWaypoint); Terminate; exit;
  if HasOption('h', 'help') or (ParamCount = 0) then begin
    WriteHelp(p);
    Terminate;
    Exit;
  end;
  if HasOption('a','a') then
     p.maxAngleDeg := StrToFloatDef(GetOptionValue('a','a'), p.maxAngleDeg);
  if HasOption('l','l') then
     p.simplifyMinLengthMM := StrToFloatDef(GetOptionValue('l','l'), p.simplifyMinLengthMM);
  if HasOption('o','o') then
     p.outName := GetOptionValue('o','o');
  if HasOption('s','s') then
     p.simplifyToleranceMM := StrToFloatDef(GetOptionValue('s','s'), p.simplifyToleranceMM);
  if HasOption('t','t') then
     p.mskThresh := StrToFloatDef(GetOptionValue('t','t'), p.mskThresh);
  for i := 1 to (ParamCount-2) do begin
    if UpperCase(paramstr(i)) = ('-W') then begin
      if nWaypoint < kMaxWayPoint then
         p.waypointName[nWaypoint] := paramstr(i+1)
      else
          showmsg('Error: Too many waypoints requested');
       nWaypoint := nWaypoint + 1;
    end;
  end;
  if HasOption('1','1') then
     p.smooth := round(StrToFloatDef(GetOptionValue('1','1'), p.smooth));
  if HasOption('2','2') then
     p.stepSize := StrToFloatDef(GetOptionValue('2','2'), p.stepSize);
  if HasOption('3','3') then
     p.minLength := round(StrToFloatDef(GetOptionValue('3','3'), p.minLength));
  if HasOption('4','4') then
     p.redundancyToleranceMM := StrToFloatDef(GetOptionValue('4','4'), p.redundancyToleranceMM);
  if HasOption('5','5') then
     p.seedsPerVoxel := round(StrToFloatDef(GetOptionValue('5','5'), p.seedsPerVoxel));

  basename := ParamStr(ParamCount);
  if not FindNiiFiles(basename, p) then begin
     WriteHelp(p);
     Terminate;
     Exit;
  end;
  if p.outName = '' then
     p.outName := ChangeFileExtX(basename, '.vtk');
  //SimplifyTracks(inname, outname, tol);
  track(p);
  Terminate;
end;

var
  Application: TFiberQuant;
begin
  Application:=TFiberQuant.Create(nil);
  Application.Title:='Tracktion';
  Application.Run;
  Application.Free;
end.

