#!/bin/bash -exo pipefail

if [ ! -z "${ECS_ALB_LISTENER}" ]
then
  aws --profile ${AWS_PROFILE} elbv2 describe-rules --listener ${ECS_ALB_LISTENER} | jq -r '[.Rules[]|select(.IsDefault == false)|{RuleArn, "TargetGroupArn":.Actions[0].TargetGroupArn}]|[{"RuleArn":.[0].RuleArn, "TargetGroupArn":.[1].TargetGroupArn},{"RuleArn":.[1].RuleArn, "TargetGroupArn":.[0].TargetGroupArn}]|.[]|"--rule-arn " + .RuleArn + " --actions Type=forward,TargetGroupArn=" + .TargetGroupArn' | xargs -n 4 aws --profile ${AWS_PROFILE} elbv2 modify-rule

elif [ ! -z "${ECS_ELB_LISTENERS}" ]
then
  _tmp=$(mktemp)
  _tmp2=$(mktemp)
  _tmp3=$(mktemp)
  _tmp4=$(mktemp)
  aws --profile ${AWS_PROFILE} elbv2 describe-listeners --listener-arns ${ECS_ELB_LISTENERS} | jq -r '[.Listeners[]|{ListenerArn, "TargetGroupArn":.DefaultActions[0].TargetGroupArn}]' | tee $_tmp
  jq < $_tmp -r '[.[].TargetGroupArn]|@sh' | xargs aws --profile ${AWS_PROFILE} elbv2 describe-tags --resource-arns | jq -r '[.TagDescriptions[]|{(.ResourceArn):.Tags[]|select(.Key == "ECS_SERVICE")|.Value}]|add' | tee $_tmp2
  jq < $_tmp -r '.[0].TargetGroupArn as $tmp|.[0].TargetGroupArn=.[1].TargetGroupArn|.[1].TargetGroupArn=$tmp' | tee $_tmp3
  jq -s -r '.[0] as $tbl | .[1][]| .TargetGroupArn as $key | . + {"EcsService":$tbl[$key]}' $_tmp2 $_tmp3 | tee $_tmp4
  IFS=$'\n'
  for arg in $(jq < $_tmp4 -r '"--listener-arn " + .ListenerArn + " --default-actions Type=forward,TargetGroupArn=" + .TargetGroupArn')
  do
    bash -c $(echo aws --profile ${AWS_PROFILE} elbv2 modify-listener $arg)
  done
  
else
  echo 'neither ECS_ALB_LISTENER and ECS_ELB_LISTENERS are configured.'
  exit 1

fi