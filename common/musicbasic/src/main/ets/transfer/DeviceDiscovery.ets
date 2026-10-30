/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { distributedDeviceManager } from '@kit.DistributedServiceKit';
import { common } from '@kit.AbilityKit';
import { Logger } from '../util/Logger';

const TAG = 'DeviceDiscovery';

/** Callback receiving device online/offline events. */
export type DeviceStateListener = (action: distributedDeviceManager.DeviceStateChange,
  device: distributedDeviceManager.DeviceBasicInfo) => void;

/** Payload of the deviceStateChange event. */
interface DeviceStateData {
  action: distributedDeviceManager.DeviceStateChange;
  device: distributedDeviceManager.DeviceBasicInfo;
}

/**
 * Thin wrapper over DistributedServiceKit: lists trusted devices and reports
 * online/offline changes (requires ohos.permission.DISTRIBUTED_DATASYNC).
 */
export class DeviceDiscovery {
  private static instance: DeviceDiscovery | undefined = undefined;
  private dm: distributedDeviceManager.DeviceManager | undefined = undefined;
  private listeners: DeviceStateListener[] = [];

  private constructor() {
  }

  /** @returns The shared discovery instance. */
  public static getInstance(): DeviceDiscovery {
    if (DeviceDiscovery.instance === undefined) {
      DeviceDiscovery.instance = new DeviceDiscovery();
    }
    return DeviceDiscovery.instance;
  }

  /** Creates the DeviceManager for the app bundle. */
  public init(context: common.Context): void {
    if (this.dm !== undefined) {
      return;
    }
    try {
      this.dm = distributedDeviceManager.createDeviceManager(context.applicationInfo.name);
      this.dm.on('deviceStateChange', (data: DeviceStateData) => {
        Logger.info(TAG, `deviceStateChange action=${data.action} name=${data.device.deviceName}`);
        for (let i = 0; i < this.listeners.length; i++) {
          this.listeners[i](data.action, data.device);
        }
      });
    } catch (err) {
      Logger.warn(TAG, `init failed: ${JSON.stringify(err)}`);
    }
  }

  /** Subscribes to device online/offline events. */
  public onDeviceStateChange(listener: DeviceStateListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  /** @returns All trusted and currently available devices. */
  public getAvailableDevices(): distributedDeviceManager.DeviceBasicInfo[] {
    if (this.dm === undefined) {
      return [];
    }
    try {
      return this.dm.getAvailableDeviceListSync();
    } catch (err) {
      Logger.warn(TAG, `getAvailableDeviceListSync failed: ${JSON.stringify(err)}`);
      return [];
    }
  }

  /** @returns The first wearable device, or undefined. */
  public findWearable(): distributedDeviceManager.DeviceBasicInfo | undefined {
    const devices = this.getAvailableDevices();
    for (let i = 0; i < devices.length; i++) {
      if (devices[i].deviceType === 'wearable') {
        return devices[i];
      }
    }
    return undefined;
  }

  /** @returns The first phone device, or undefined. */
  public findPhone(): distributedDeviceManager.DeviceBasicInfo | undefined {
    const devices = this.getAvailableDevices();
    for (let i = 0; i < devices.length; i++) {
      if (devices[i].deviceType === 'phone') {
        return devices[i];
      }
    }
    return undefined;
  }

  /** @returns The network id used for hmdfs connections. */
  public networkIdOf(device: distributedDeviceManager.DeviceBasicInfo): string {
    if (device.networkId !== undefined && device.networkId !== '') {
      return device.networkId;
    }
    return device.deviceId;
  }
}
