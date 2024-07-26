{{- define "branchName" -}}
{{- if eq .Values.branch "main" -}}
{{- /* Return empty string if branch is main */ -}}
{{- else -}}
{{- .Values.branch -}}
{{- end -}}
{{- end -}}