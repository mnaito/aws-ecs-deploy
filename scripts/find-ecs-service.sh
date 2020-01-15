#!/bin/bash -exo pipefail

if [ ! -z "${ECS_ALB_LISTENER}" ]
then
  PREVIEW_TARGET_GROUP=$(aws --profile ${AWS_PROFILE} elbv2 describe-rules --listener ${ECS_ALB_LISTENER} | jq -r '.Rules[]|select(.Priority == "1")|.Actions[].TargetGroupArn')
  aws --profile ${AWS_PROFILE} ecs describe-services --cluster ${ECS_CLUSTER_NAME} --services ${ECS_BLUE_SERVICE_NAME} ${ECS_GREEN_SERVICE_NAME} | jq -r '.services[]|{"targetGroupArn":.loadBalancers[0].targetGroupArn, serviceName}|select(.targetGroupArn == "'${PREVIEW_TARGET_GROUP}'")|.serviceName'
  
elif [ ! -z "${ECS_ELB_LISTENERS}" ]
then
  _tmp=$(mktemp)
  _tmp2=$(mktemp)
  _tmp3=$(mktemp)
  _tmp4=$(mktemp)
  aws --profile ${AWS_PROFILE} elbv2 describe-listeners --listener-arns ${ECS_ELB_LISTENERS} | jq -r '[.Listeners[]|{ListenerArn, "TargetGroupArn":.DefaultActions[0].TargetGroupArn}]' > $_tmp
  jq < $_tmp -r '[.[].TargetGroupArn]|@sh' | xargs aws --profile ${AWS_PROFILE} elbv2 describe-tags --resource-arns | jq -r '[.TagDescriptions[]|{(.ResourceArn):.Tags[]|select(.Key == "ECS_SERVICE")|.Value}]|add' > $_tmp2
  jq < $_tmp -r '.[0].TargetGroupArn as $tmp|.[0].TargetGroupArn=.[1].TargetGroupArn|.[1].TargetGroupArn=$tmp' > $_tmp3
  jq -s -r '[.[0] as $tbl | .[1][]| .TargetGroupArn as $key | . + {"EcsService":$tbl[$key]}]' $_tmp2 $_tmp3 > $_tmp4
  jq < $_tmp4 -r '.[0].EcsService'
  
else
  echo ${ECS_SERVICE_NAME}

fi