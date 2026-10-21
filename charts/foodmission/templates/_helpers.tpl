{{/*
Prefer scheduling next to the CNPG primary, in the same zone (Hetzner
location). DB jobs send many small sequential queries, and a round trip
hel1 -> nbg1 costs ~25ms vs <1ms within a location.
Preferred, not required: the pod still runs if that location has no room.
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
{{- end }}
