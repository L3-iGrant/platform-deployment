// Command psscheck checks each pod template of rendered manifests against a
// level of the Pod Security Standards with the upstream library
// k8s.io/pod-security-admission: the code of the admission plugin of
// Kubernetes. It covers each control of the standard, also the controls
// that tests/check_security.py does not have (AppArmor, SELinux, procMount,
// hostProcess, the ephemeral containers and the annotations of the pod).
//
// Usage:
//
//	psscheck -level restricted -version latest [-containers N] <render.yaml>...
//
// The checker reads the kinds Pod, Deployment, StatefulSet, DaemonSet,
// ReplicaSet, ReplicationController, Job, CronJob and PodTemplate. It
// stops with exit code 1 when a pod template breaks the level, when a
// document cannot be read, when a document of another kind has
// containers (a kind that the checker does not know), or when the count
// of the containers (init, normal and ephemeral) is not -containers (the
// count of tests/check_security.py: both checkers read the same
// containers). It reads only the pod specs: never a Secret value.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	utilyaml "k8s.io/apimachinery/pkg/util/yaml"
	"k8s.io/pod-security-admission/api"
	"k8s.io/pod-security-admission/policy"
)

type head struct {
	Kind     string `json:"kind"`
	Metadata struct {
		Name string `json:"name"`
	} `json:"metadata"`
}

type result struct {
	files, pods, containers int
	problems                []string
}

func main() {
	levelText := flag.String("level", "restricted", "the level: privileged, baseline or restricted")
	versionText := flag.String("version", "latest", "the version of the standard, for example latest or v1.30")
	want := flag.Int("containers", -1, "the expected count of containers (-1: no check, but at least 1)")
	flag.Parse()
	level, err := api.ParseLevel(*levelText)
	if err != nil {
		fail(err)
	}
	version, err := api.ParseVersion(*versionText)
	if err != nil {
		fail(err)
	}
	if flag.NArg() == 0 {
		fail(errors.New("give one or more rendered manifests"))
	}
	evaluator, err := policy.NewEvaluator(policy.DefaultChecks(), nil)
	if err != nil {
		fail(err)
	}
	r := result{}
	for _, path := range flag.Args() {
		if err := r.checkFile(evaluator, api.LevelVersion{Level: level, Version: version}, path); err != nil {
			r.problems = append(r.problems, fmt.Sprintf("%s: %v", filepath.Base(path), err))
		}
	}
	if *want >= 0 && r.containers != *want {
		r.problems = append(r.problems, fmt.Sprintf("%d containers, not %d (the count of tests/check_security.py)", r.containers, *want))
	}
	if *want < 0 && r.containers == 0 {
		r.problems = append(r.problems, "no container in the renders")
	}
	for _, problem := range r.problems {
		fmt.Printf("  FAIL: %s\n", problem)
	}
	fmt.Printf("pss %s:%s: %d files, %d pod templates, %d containers, %d problems\n", *levelText, *versionText, r.files, r.pods, r.containers, len(r.problems))
	if len(r.problems) > 0 {
		os.Exit(1)
	}
}

func (r *result) checkFile(evaluator policy.Evaluator, lv api.LevelVersion, path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	r.files++
	decoder := utilyaml.NewYAMLOrJSONDecoder(bytes.NewReader(data), 4096)
	for {
		var raw json.RawMessage
		if err := decoder.Decode(&raw); err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return fmt.Errorf("cannot read a document: %w", err)
		}
		if len(raw) == 0 || string(raw) == "null" {
			continue
		}
		var h head
		if err := json.Unmarshal(raw, &h); err != nil {
			return fmt.Errorf("cannot read a document: %w", err)
		}
		meta, spec, err := podOf(h.Kind, raw)
		if err != nil {
			return fmt.Errorf("%s/%s: %w", h.Kind, h.Metadata.Name, err)
		}
		if spec == nil {
			if bytes.Contains(raw, []byte(`"containers"`)) {
				r.problems = append(r.problems, fmt.Sprintf("%s: %s/%s has containers, but the checker does not know the kind", filepath.Base(path), h.Kind, h.Metadata.Name))
			}
			continue
		}
		r.pods++
		r.containers += len(spec.InitContainers) + len(spec.Containers) + len(spec.EphemeralContainers)
		for _, check := range evaluator.EvaluatePod(lv, meta, spec) {
			if !check.Allowed {
				r.problems = append(r.problems, fmt.Sprintf("%s: %s/%s: %s: %s", filepath.Base(path), h.Kind, h.Metadata.Name, check.ForbiddenReason, check.ForbiddenDetail))
			}
		}
	}
}

// podOf gives the metadata and the spec of the pod (template) of a
// document, or a nil spec for a kind without a pod.
func podOf(kind string, raw []byte) (*metav1.ObjectMeta, *corev1.PodSpec, error) {
	strict := func(target any) error {
		decoder := json.NewDecoder(bytes.NewReader(raw))
		decoder.DisallowUnknownFields()
		return decoder.Decode(target)
	}
	switch kind {
	case "Pod":
		var o corev1.Pod
		err := strict(&o)
		return &o.ObjectMeta, &o.Spec, err
	case "PodTemplate":
		var o corev1.PodTemplate
		err := strict(&o)
		return &o.Template.ObjectMeta, &o.Template.Spec, err
	case "Deployment":
		var o appsv1.Deployment
		err := strict(&o)
		return &o.Spec.Template.ObjectMeta, &o.Spec.Template.Spec, err
	case "StatefulSet":
		var o appsv1.StatefulSet
		err := strict(&o)
		return &o.Spec.Template.ObjectMeta, &o.Spec.Template.Spec, err
	case "DaemonSet":
		var o appsv1.DaemonSet
		err := strict(&o)
		return &o.Spec.Template.ObjectMeta, &o.Spec.Template.Spec, err
	case "ReplicaSet":
		var o appsv1.ReplicaSet
		err := strict(&o)
		return &o.Spec.Template.ObjectMeta, &o.Spec.Template.Spec, err
	case "ReplicationController":
		var o corev1.ReplicationController
		if err := strict(&o); err != nil || o.Spec.Template == nil {
			return nil, nil, errors.Join(err, errors.New("no pod template"))
		}
		return &o.Spec.Template.ObjectMeta, &o.Spec.Template.Spec, nil
	case "Job":
		var o batchv1.Job
		err := strict(&o)
		return &o.Spec.Template.ObjectMeta, &o.Spec.Template.Spec, err
	case "CronJob":
		var o batchv1.CronJob
		err := strict(&o)
		return &o.Spec.JobTemplate.Spec.Template.ObjectMeta, &o.Spec.JobTemplate.Spec.Template.Spec, err
	}
	return nil, nil, nil
}

func fail(err error) {
	fmt.Fprintf(os.Stderr, "psscheck: %v\n", strings.TrimSpace(err.Error()))
	os.Exit(2)
}
