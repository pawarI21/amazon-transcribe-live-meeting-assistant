#!/bin/bash

##############################################################################################
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
##############################################################################################

##############################################################################################
# Create new Cfn artifacts bucket if not already existing, and publish template and artifacts
# usage: ./publish.sh <cfn_bucket> <cfn_prefix> <region> [public]
##############################################################################################
# Stop the publish process on failures
set -e

# use current directory name as template name
NAME=$(basename `pwd`)

USAGE="$0 <cfn_bucket> <cfn_prefix> <region> [public]"

BUCKET=$1
[ -z "$BUCKET" ] && echo "Cfn bucket name is required parameter. Usage $USAGE" && exit 1

PREFIX=$2
[ -z "$PREFIX" ] && echo "Prefix is required parameter. Usage $USAGE" && exit 1

# Remove trailing slash from prefix if needed
[[ "${PREFIX}" == */ ]] && PREFIX="${PREFIX%?}"

REGION=$3
[ -z "$REGION" ] && echo "Region is a required parameter. Usage $USAGE" && exit 1
export AWS_DEFAULT_REGION=$REGION

ACL=$4
if [ "$ACL" == "public" ]; then
  echo "Published S3 artifacts will be acessible by public (read-only)"
  PUBLIC=true
else
  echo "Published S3 artifacts will NOT be acessible by public."
  PUBLIC=false
fi

# Create bucket if it doesn't already exist
if [ -x $(aws s3api list-buckets --query 'Buckets[].Name' | grep "\"$BUCKET\"") ]; then
  echo "Creating s3 bucket: $BUCKET"
  aws s3 mb s3://${BUCKET} || exit 1
  aws s3api put-bucket-versioning --bucket ${BUCKET} --versioning-configuration Status=Enabled || exit 1
else
  echo "Using existing bucket: $BUCKET"
fi

echo -n "Make temp dir: "
timestamp=$(date "+%Y%m%d_%H%M")
tmpdir=/tmp/$NAME
[ -d $tmpdir ] && rm -fr $tmpdir
mkdir -p $tmpdir

template=template.yaml
s3_template="s3://${BUCKET}/${PREFIX}/${NAME}/template.yaml"
https_template="https://s3.${REGION}.amazonaws.com/${BUCKET}/${PREFIX}/${NAME}/template.yaml"

echo "PACKAGING $NAME"
aws cloudformation package \
--template-file ${template} \
--output-template-file ${tmpdir}/tmp.template.yaml \
--s3-bucket $BUCKET --s3-prefix ${PREFIX}/${NAME} \
--region ${REGION} || exit 1

echo "Inline edit ${tmpdir}/tmp.template.yaml to replace "
echo "   <ARTIFACT_BUCKET_TOKEN> with bucket name: $BUCKET"
echo "   <ARTIFACT_PREFIX_TOKEN> with prefix: $PREFIX"
echo "   <REGION_TOKEN> with region: $REGION"
cat ${tmpdir}/tmp.template.yaml | 
sed -e "s%<ARTIFACT_BUCKET_TOKEN>%$BUCKET%g" | 
sed -e "s%<ARTIFACT_PREFIX_TOKEN>%$PREFIX%g" |
sed -e "s%<REGION_TOKEN>%$REGION%g" > ${tmpdir}/${template}

echo "Uploading template file to: ${s3_template}"
aws s3 cp ${tmpdir}/${template} ${s3_template}
echo "Validating template"
aws cloudformation validate-template --template-url ${https_template} > /dev/null || exit 1
echo "Validated: ${https_template}"

if $PUBLIC; then
  echo "Setting public read ACLs on published artifacts"
  files=$(aws s3api list-objects --bucket ${BUCKET} --prefix ${PREFIX} --query "(Contents)[].[Key]" --output text)
  for file in $files
    do
    aws s3api put-object-acl --acl public-read --bucket ${BUCKET} --key $file
    done
fi

echo Published $NAME - Template URL: $https_template
exit 0

