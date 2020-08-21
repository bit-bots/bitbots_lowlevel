#include <bitbots_ros_control/leds_hardware_interface.h>
#include <bitbots_ros_control/utils.h>

namespace bitbots_ros_control {
LedsHardwareInterface::LedsHardwareInterface() {}

LedsHardwareInterface::LedsHardwareInterface(std::shared_ptr<DynamixelDriver> &driver, uint8_t id, uint8_t num_leds) {
  driver_ = driver;
  id_ = id;
  leds_.resize(num_leds);
  // we want to write the LEDs in the beginning to show that ros control started successfully. set LED 1 white
  write_leds_ = true;
  leds_[0] = std_msgs::ColorRGBA();
  leds_[0].r = 1.0;
  leds_[0].g = 1.0;
  leds_[0].b = 1.0;
  leds_[0].a = 1.0;
}

bool LedsHardwareInterface::init(ros::NodeHandle &nh, ros::NodeHandle &hw_nh) {
  nh_ = nh;
  leds_service_ = nh_.advertiseService("/set_leds", &LedsHardwareInterface::setLeds, this);

  return true;
}

void LedsHardwareInterface::read(const ros::Time &t, const ros::Duration &dt) {}

bool LedsHardwareInterface::setLeds(bitbots_msgs::LedsRequest &req, bitbots_msgs::LedsResponse &resp) {
  if (req.leds.size() != leds_.size()) {
    ROS_WARN_STREAM(
        "You are trying to set " << req.leds.size() << " leds while the board has " << leds_.size() << " leds.");
    return false;
  }

  for (int i = 0; i < leds_.size(); i++) {
    // return current state of LEDs
    resp.previous_leds.push_back(leds_[i]);

    if (req.leds[i].r > 1.0f || req.leds[i].r < 0.0f ||
        req.leds[i].g > 1.0f || req.leds[i].g < 0.0f ||
        req.leds[i].b > 1.0f || req.leds[i].b < 0.0f) {
      ROS_WARN_STREAM("You tried to set LED_" << i << " to a value not between 0 and 1");
      return false;
    }
    leds_[i] = req.leds[i];
  }
  write_leds_ = true;
  return true;
}

uint32_t rgba_to_int32(std_msgs::ColorRGBA rgba) {
  uint32_t led = (uint8_t) rgba.r * 255;
  led |= ((uint8_t) (rgba.g * 255)) << 8;
  led |= ((uint8_t) (rgba.b * 255)) << 16;
  led |= ((uint8_t) (rgba.a * 255)) << 24;
  return led;
}

void LedsHardwareInterface::write(const ros::Time &t, const ros::Duration &dt) {
  if (write_leds_) {
    // resort LEDs to go from left to right
    driver_->writeRegister(id_, "LED_2", rgba_to_int32(leds_[0]));
    driver_->writeRegister(id_, "LED_1", rgba_to_int32(leds_[1]));
    driver_->writeRegister(id_, "LED_0", rgba_to_int32(leds_[2]));

    write_leds_ = false;
  }
}
}