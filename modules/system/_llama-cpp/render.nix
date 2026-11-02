{ lib, cfg }:
{
  # Shared router policy; platform adapters add only platform/service flags.
  routerFlags = [
    "--models-max"
    "1"
    "--sleep-idle-seconds"
    (toString cfg.sleepIdleSeconds)
  ];
  modelsPreset = lib.mapAttrs (
    name: model:
    {
      hf-repo = name;
      c = model.ctxSize;
      n-gpu-layers = model.nGpuLayers;
      ctk = model.cacheTypeK;
      ctv = model.cacheTypeV;
    }
    # Omitted rather than written as 0 for a dense model: the
    # flag is meaningless without experts and leaving it out
    # keeps the rendered preset readable as a description of
    # what each model actually needs.
    // lib.optionalAttrs (model.nCpuMoeLayers > 0) {
      n-cpu-moe = model.nCpuMoeLayers;
    }
    // lib.optionalAttrs (model.aliases != [ ]) {
      alias = lib.concatStringsSep "," model.aliases;
    }
  ) cfg.models;

}
