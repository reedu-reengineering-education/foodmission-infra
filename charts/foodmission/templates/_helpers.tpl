{{/*
Prefer scheduling next to the CNPG primary, in the same zone (Hetzner
location), not necessarily on the same node. DB jobs send many small
sequential queries, and a round trip hel1 -> nbg1 costs ~25ms vs <1ms
within a location. The zone rule is preferred, not required: the pod
still runs if that location has no room.

If api.jobInstanceType is set, the jobs are restricted to that node type
(required). It has to be required: the scheduler normalizes each affinity
plugin to 0-100, so a second *preferred* rule would tie with the zone rule
and a big node in another location could win on free resources. With the
node type required, the zone rule picks the big node next to the primary.
No free node of that type: the pod stays Pending and the autoscaler adds one.
*/}}
{{- define "foodmission.dbPrimaryAffinity" -}}
affinity:
  podAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: topology.kubernetes.io/zone
          labelSelector:
            matchLabels:
              cnpg.io/cluster: {{ .Values.global.cnpg.clusterName }}
              cnpg.io/instanceRole: primary
  {{- with .Values.api.jobInstanceType }}
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: node.kubernetes.io/instance-type
              operator: In
              values:
                - {{ . }}
  {{- end }}
{{- end }}
