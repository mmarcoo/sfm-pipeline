#!/bin/bash

################################################################################
# Procedures and Functions                                                     #
################################################################################
showHelp() {
cat << EOF
Usage: ./sfm_pipeline -i <video/images path> -s <samples per second> -c <colmap-dir>  -o <openmvs-dir>

-h, -help,          --help                 Display help
 
-i, -input,         --input,               [Required] Select the folder with video or images.

-s, -samples,       --samples              [Optional - Default 1] If input is video, this decides how many samples per second are used.

-c, -colmap,        --colmap               [Optional] Specify colmap bin directory

-m, -openmvs,       --openmvs              [Optional] Specify openmvs bin directory

EOF
}

function printStatus {
	echo -ne "\033]2;$1\007"
	echo -ne "\033[1;35m[ $1 ]\033[0m\n"
}

################################################################################
################################################################################
# Main program                                                                 #
################################################################################
################################################################################

################################################################################
# Process the input options.                                                   # 
################################################################################

# Define variables
export INPUT=-1
export COLMAP_BIN_DIRECTORY="~"
export SAMPLES=1
export OPENMVS_BIN_DIRECTORY="~"

# Get options from command line
options=$(getopt -l "help,input:,samples:,colmap:,openmvs:" -o "hi:s:c:m:" -a -- "$@")
eval set -- "$options"

# Process the inputs
while true
do
case $1 in
-h|--help) 
    showHelp
    exit 0
    ;;
-i|--input) 
    shift
    export INPUT=$1
    ;;
-s|--samples) 
    shift
    export SAMPLES=$1
    ;;
-c|--colmap) 
    shift
    export COLMAP_BIN_DIRECTORY=$1
    ;;
-m|--openmvs) 
    shift
    export OPENMVS_BIN_DIRECTORY=$1
    ;;
--)
    shift
    break;;
esac
shift
done

# Check the only requirement
if [ -z $INPUT ]; then
	echo "Invalid input directory, check '--help' for more information on the usage."
	exit 127
fi

################################################################################
# Check if CUDA is available and new enough.                                   #
################################################################################

NVCC=`which nvcc`
if [ -z $NVCC ] && [ -z $NO_CUDA_CHECK ]; then
	echo "Your system does not appear to have CUDA support. (Set NO_CUDA_CHECK=1 to ignore)"
	exit 2
else
	CUDAVER=`$NVCC --version | grep release | sed -e 's/^.*V\([0-9]*\.[0-9]*\).*$/\1/'`
	
	OLD_CUDA=`echo "$CUDAVER > 7.5" | bc -l`
	if [ $OLD_CUDA -ne "1" ] && [ -z $NO_CUDA_CHECK ]; then
		echo "CUDA v7.5 or greater is required. You appear to have v$CUDAVER. (Set NO_CUDA_CHECK=1 to ignore)"
		exit 2
	fi
fi

################################################################################
# Find Colmap's executable directory.                                          #
################################################################################

CM=$COLMAP_PATH
which $CM/colmap &>/dev/null
if [ "$?" -ne "0" ]; then
	CM=$COLMAP_BIN_DIRECTORY
	
	which $CM/colmap &>/dev/null
	if [ "$?" -ne "0" ]; then
		CM=`which colmap 2>/dev/null | xargs dirname 2>/dev/null` 
		
		which $CM/colmap &>/dev/null
		if [ "$?" -ne "0" ]; then
			echo "Colmap executables not found, try setting COLMAP_BIN_DIRECTORY correctly."
			exit 2
		fi
		
	fi
fi

################################################################################
# Find OpenMVS's executable directory                                          #
################################################################################

MVS=$OPENMVS_PATH
which $MVS/InterfaceVisualSFM &>/dev/null
if [ "$?" -ne "0" ]; then
	MVS=$OPENMVS_BIN_DIRECTORY
	
	which $MVS/InterfaceVisualSFM &>/dev/null
	if [ "$?" -ne "0" ]; then
		MVS=`which InterfaceVisualSFM 2>/dev/null | xargs dirname 2>/dev/null` 
		
		which $MVS/InterfaceVisualSFM &>/dev/null
		if [ "$?" -ne "0" ]; then
			echo "OpenMVS executables not found, try setting OPENMVS_BIN_DIRECTORY correctly."
			exit 2
		fi
		
	fi
fi

################################################################################
# Reorganize project directory and process video file if necessary.            #
################################################################################

PP=`realpath $INPUT`
if [ ! -d "$PP/raw" ]; then
	mkdir $PP/raw
	
	MP4=`ls $PP/*.mp4| head -n 1`
	
	if [ -f "$MP4" ]; then
		rm -f "$PP/raw/*.jpg"
		
		printStatus "0/9 - Extracting Video"
		
		# if your video frames are blurry so will be your model's texture
		ffmpeg -i "$MP4" -r "$SAMPLES/1" "$PP/raw/output_%04d.jpg"
		find $PP/raw -name '*.jpg' -print0 | xargs -0 exiftool -TagsFromFile $PP/../stereotype.jpg 
		rm -f $PP/raw/*.jpg_original
	else
		mv $PP/*.jpg $PP/raw
	fi
fi

################################################################################
# Main pipeline.                                                               #
################################################################################

# Creating script_cache
SC=$PP/script_cache
mkdir -p $SC

# Feature Extraction
if [ ! -f $SC/1 ]; then
	printStatus "1/9 - Feature Extractor"
	($CM/colmap feature_extractor --database_path $PP/colmap.db --image_path $PP/raw \
	&& touch $SC/1) || exit
fi

# Features Matching
if [ ! -f $SC/2 ]; then
	printStatus "2/9 - Feature Matching"
	($CM/colmap exhaustive_matcher --database_path $PP/colmap.db \
	&& touch $SC/2) || exit
fi

# Sparse Point Cloud Generation
if [ ! -f $SC/3 ]; then
	printStatus "3/9 - Colmap mapper"
mkdir -p $PP/sparse
	($CM/colmap mapper --database_path $PP/colmap.db --image_path $PP/raw --output_path $PP/sparse \
	&& touch $SC/3)  || exit
fi
if [ ! -d $PP/sparse/0 ]; then
	touch $PP/insufficient
	echo -e "\e[1;31m\n\nImage set is insufficient to reconstruct a mesh. \e[0m\n\n"
	exit 3
fi

# Save Colmap to nvm format
if [ ! -f $SC/4 ]; then
	printStatus "4/9 - Colmap Model Converter"
	($CM/colmap model_converter --input_path $PP/sparse/0 --output_path $PP/model.nvm --output_type nvm \
	&& touch $SC/4)  || exit
fi

# Convert the Colmap model to use it with OpenMVS
if [ ! -f $SC/5 ]; then
	printStatus "5/9 - OpenMVS NVM->MVS"
	($MVS/InterfaceVisualSFM -w $PP/raw -i $PP/model.nvm -o $PP/model.mvs --output-image-folder $PP/mvs_images -v 2 \
	&& touch $SC/5) || exit
fi

# Create Dense Point Cloud
if [ ! -f $SC/6 ]; then
	printStatus "6/9 - OpenMVS Densify Point Cloud"
	($MVS/DensifyPointCloud -w $PP/raw -i $PP/model.mvs -o $PP/model_dense.mvs --resolution-level 2 --estimate-colors 0 -v 2 \
	&& touch $SC/6) || exit
fi

# Reconstruct the Mesh
if [ ! -f $SC/7 ]; then
	printStatus "7/9 - OpenMVS Mesh Reconstruction"
	($MVS/ReconstructMesh -w $PP/raw -i $PP/model_dense.mvs -o $PP/model_dense_mesh.mvs -d 4 -v 2 \
	&& touch $SC/7) || exit
fi

# Refine the Mesh
if [ ! -f $SC/8 ]; then
	printStatus "8/9 - OpenMVS Mesh Refinement"
	($MVS/RefineMesh -w $PP/raw \
		-i $PP/model_dense_mesh.mvs \
		-o $PP/model_dense_mesh_refine.mvs \
		--use-cuda 1 \
		--resolution-level 1 \
		-v 2 \
	&& touch $SC/8) || exit
fi

# Apply texture to the mesh
if [ ! -f $SC/9 ]; then
	printStatus "9/9 - OpenMVS Mesh Texturing"
	($MVS/TextureMesh -w $PP/raw \
		-i $PP/model_dense_mesh_refine.mvs \
		-o $PP/model_dense_mesh_refine_texture.mvs \
		--empty-color 0  \
		-v 2 \
	&& touch $SC/8) || exit
fi
