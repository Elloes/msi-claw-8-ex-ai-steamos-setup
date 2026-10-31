import { FC } from "react";
import { CpuBoostModes } from "../../backend/utils";
import { DeckySlider, NotchLabel } from "./DeckyFrontendLib";
import t from "../../i18n/i18n";

const MODES = [CpuBoostModes.OFF, CpuBoostModes.SMART, CpuBoostModes.FULL];

const getNotchLabels = (): NotchLabel[] => [
  { notchIndex: 0, value: 0, label: t("CPU_BOOST_MODE_OFF", "Off") },
  { notchIndex: 1, value: 1, label: t("CPU_BOOST_MODE_SMART", "Smart") },
  { notchIndex: 2, value: 2, label: t("CPU_BOOST_MODE_FULL", "Full") },
];

const CpuBoostModeSlider: FC<{
  cpuBoostMode: CpuBoostModes;
  setCpuBoostMode: (mode: CpuBoostModes) => void;
}> = ({ cpuBoostMode, setCpuBoostMode }) => {
  return (
    <DeckySlider
      label={t("CPU_CONTROLS_BOOST_MODE", "CPU Boost")}
      value={MODES.indexOf(cpuBoostMode)}
      min={0}
      max={MODES.length - 1}
      step={1}
      notchCount={MODES.length}
      notchLabels={getNotchLabels()}
      notchTicksVisible
      showValue={false}
      bottomSeparator={"none"}
      onChange={(value: number) => setCpuBoostMode(MODES[value])}
    />
  );
};

export default CpuBoostModeSlider;
