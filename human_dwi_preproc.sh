#!/bin/bash
source `which my_do_cmd`
module load ANTs singularity

dwiFull=$1
dwirevpe=$2
outbase=$3
nthreads=$4

tmpDir=$(mktemp -d dwipreproc-XXXXXXXXXX)

b0=${tmpDir}/b0.nii
b0revpe=${tmpDir}/b0revpe.nii
b0pair=${tmpDir}/b0pair.nii
json=${dwiFull%.nii*}.json; # provides multiband factor and slice timings.
singularity_container=/home/inb/soporte/lanirem_software/containers/designer2_v2.0.10.sif
bvecs=${dwiFull%.nii*}.bvec
bvals=${dwiFull%.nii*}.bval
outbase=${outbase%.nii*}; # remove extension if provided

echolor cyan "[INFO] dwiFull  : $dwiFull"
echolor cyan "[INFO] bvals    : $bvals"
echolor cyan "[INFO] bvecs    : $bvecs"
echolor cyan "[INFO] json     : $json"
echolor cyan "[INFO] dwirevpe : $dwirevpe"
echolor cyan "[INFO] nthreads : $nthreads"
echolor cyan "[INFO] designer : $singularity_container"
echolor cyan "[INFO] outbase  : $outbase"

my_do_cmd mrconvert -coord 3 0 $dwiFull $b0
my_do_cmd mrconvert $dwirevpe $b0revpe  # Modificación porque el rpe no tiene 4 dir
#my_do_cmd mrconvert -coord 3 0 $dwirevpe $b0revpe    Linea original del script del doc
my_do_cmd mrcat -axis 3 $b0 $b0revpe $b0pair  


## Denoise, degibbs, rician
echolor green "[INFO] Will perform denoising, degibss, and rician correction through Designer"
singularity run --nv $singularity_container designer \
  -mask -denoise -degibbs -rician \
  -pe_dir AP -pf 6/8 \
  $dwiFull \
  ${tmpDir}/denoised_unringed.nii.gz
dwiFull=${tmpDir}/denoised_unringed.nii.gz
bvecs=${dwiFull%.nii*}.bvec
bvals=${dwiFull%.nii*}.bval
echolor cyan "[INFO] After designerv2, inputs for topup are:"
echolor cyan "[INFO] dwiFull  : $dwiFull"
echolor cyan "[INFO] bvals    : $bvals"
echolor cyan "[INFO] bvecs    : $bvecs"
echolor cyan "[INFO] json     : $json"
echolor cyan "[INFO] dwirevpe : $dwirevpe"
echo ""

## topup
echolor green "[INFO] Topup outside of container"
acqparams=${tmpDir}/acqparams.txt
printf "0 -1 0 0.0502979\n0 1 0 0.0502979" > $acqparams # phase encoding direction vector: dx dy dx  and timereadout (got it from the json file)
cat $acqparams
index=${tmpDir}/index.txt
indx=""
for ((i=1; i<=143; i+=1)); do indx="$indx 1"; done  # 
echo $indx > $index
cat $index

out_topup=${outbase}_topupout
iout=${outbase}_topupout_hifi_b0
my_do_cmd topup \
  --imain=$b0pair \
  --datain=$acqparams \
  --config=b02b0.cnf \
  --out=$out_topup \
  --iout=$iout \
  --nthr=${nthreads} \
  --verbose

# Modificacion de cómo se obtiene la mascara, antes era con bet
echolor green "[INFO] Brain mask"
mrconvert -coord 3 0 $iout.nii.gz ${tmpDir}/topup_b0_extracted.nii.gz
brain=${tmpDir}/topup_b0_extracted.nii.gz
mask=${tmpDir}/brain_mask.nii.gz
mri_synthstrip -i $brain -m $mask



#brain=${tmpDir}/brain
#mri_synthstrip -i $brain -m brain_mask.nii.gz
#mask=${tmpDir}/brain_mask
echolor cyan "[INFO] mask : $mask"
echo ""

#Hacer desde aquí con la mascara corregida
echolor green "[INFO] Eddy outside of container"
my_do_cmd eddy_cuda10.2 \
  --imain=${dwiFull} \
  --mask=$mask \
  --acqp=$acqparams \
  --index=$index \
  --bvecs=$bvecs \
  --bvals=$bvals \
  --json=${json} \
  --topup=$out_topup \
  --out=${outbase}_eddy_corrected_data \
  --repol=true \
  --residuals=true \
  --verbose \
  --data_is_shelled


## biasfield correction now because it was not working in container
echolor green "[INFO] bias field correction outside of container"
my_do_cmd dwibiascorrect ants \
  -fslgrad ${outbase}_eddy_corrected_data.eddy_rotated_bvecs $bvals \
  -bias ${outbase}_eddy_corrected_data_biasfield.nii.gz \
  ${outbase}_eddy_corrected_data.nii.gz \
  ${outbase}_eddy_corrected_data_biascorrected.nii.gz
  
  
## Convert the final output to mif format with gradient information
finalFile=${outbase}_fullypreprocessed.mif
echolor green "[INFO] Conversion to mif"
my_do_cmd mrconvert \
  -fslgrad ${outbase}_eddy_corrected_data.eddy_rotated_bvecs $bvals \
  -append_property "preproc" "denoise,unring,rician,topup-eddy,biasfieldcorr" \
  -append_property "preproc_by" $USER \
  -clear_property command_history \
   ${outbase}_eddy_corrected_data_biascorrected.nii.gz \
   $finalFile
echolor yellow "[INFO] Fully preprocessed file : $finalFile"

## QC
echolor green "[INFO] Running QC"
my_do_cmd eddy_quad \
  ${outbase}_eddy_corrected_data \
  -idx $index \
  -par $acqparams \
  -m $mask \
  -b $bvals \
  -g $bvecs \
  -j $json \
  -v
  
echolor cyan "[INFO] We are done!"
#rm -fR $tmpDir


