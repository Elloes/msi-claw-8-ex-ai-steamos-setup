import { useDispatch, useSelector } from "react-redux";
import {
  getCurrentCpuBoostModeSelector,
  getCurrentCpuBoostSelector,
  setCpuBoost,
  setCpuBoostMode,
} from "../redux-modules/settingsSlice";
import { useCallback } from "react";
import { CpuBoostModes } from "../backend/utils";

export const useCpuBoost = () => {
  const cpuBoost = useSelector(getCurrentCpuBoostSelector);
  const cpuBoostMode = useSelector(getCurrentCpuBoostModeSelector);
  const dispatch = useDispatch();

  const setter = useCallback((enabled: boolean) => {
    return dispatch(setCpuBoost(enabled));
  }, []);

  const modeSetter = useCallback((mode: CpuBoostModes) => {
    return dispatch(setCpuBoostMode(mode));
  }, []);

  return {
    cpuBoost,
    setCpuBoost: setter,
    cpuBoostMode,
    setCpuBoostMode: modeSetter,
  };
};
