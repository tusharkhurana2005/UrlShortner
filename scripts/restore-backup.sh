#!/usr/bin/env bash
# Restores the Urls database from a backup archive on the backup volume.
#   ./scripts/restore-backup.sh            (newest archive)
#   ./scripts/restore-backup.sh urls-20261018T020000Z.archive.gz
# Runs as a one-off Job with the same labels/security as the backup CronJob, so
# the existing NetworkPolicy lets it reach MongoDB and nothing else.
source "$(dirname "$0")/lib.sh"
require kubectl

ARCHIVE="${1:-latest}"
JOB="mongodb-restore-$(date +%s)"
MONGO_HOST="${RELEASE}-mongodb-0.${RELEASE}-mongodb.${NAMESPACE}.svc.cluster.local"
IMAGE="$(kubectl -n "${NAMESPACE}" get statefulset "${RELEASE}-mongodb" -o jsonpath='{.spec.template.spec.containers[0].image}')"

log "Restoring ${ARCHIVE} into ${MONGO_HOST} (job ${JOB})"
kubectl -n "${NAMESPACE}" apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: urlshortener
        app.kubernetes.io/instance: ${RELEASE}
        app.kubernetes.io/component: mongodb-backup
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: restore
          image: ${IMAGE}
          command: ["/bin/bash", "-ec"]
          args:
            - |
              f="${ARCHIVE}"
              if [[ "\$f" == latest ]]; then f="\$(ls -1t /backup/urls-*.archive.gz | head -1)"; else f="/backup/\$f"; fi
              echo "restoring \$f"
              mongorestore --uri="mongodb://\${MONGO_USER}:\${MONGO_PASSWORD}@${MONGO_HOST}:27017/Urls?authSource=Urls" \
                --nsInclude='Urls.*' --drop --archive="\$f" --gzip
          env:
            - name: MONGO_USER
              valueFrom: { secretKeyRef: { name: urlshortener-mongo, key: app-username } }
            - name: MONGO_PASSWORD
              valueFrom: { secretKeyRef: { name: urlshortener-mongo, key: app-password } }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits: { memory: 256Mi }
          volumeMounts:
            - { name: backup, mountPath: /backup, readOnly: true }
            - { name: tmp, mountPath: /tmp }
      volumes:
        - name: backup
          persistentVolumeClaim:
            claimName: backup-${RELEASE}-mongodb-0
            readOnly: true
        - name: tmp
          emptyDir: {}
YAML
kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${JOB}" --timeout=300s
kubectl -n "${NAMESPACE}" logs "job/${JOB}" | tail -5
log "Restore finished"
