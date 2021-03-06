#include <ros/callback_queue.h>
#include <controller_manager/controller_manager.h>
#include <bitbots_ros_control/wolfgang_hardware_interface.h>
#include <signal.h>
#include <thread>
sig_atomic_t volatile request_shutdown = 0;

void sigintHandler(int sig) {
  // gives other nodes some time to perform shutdown procedures with robot
  request_shutdown = 1;
}

int main(int argc, char *argv[]) {
  ros::init(argc, argv, "ros_control", ros::init_options::NoSigintHandler);
  signal(SIGINT, sigintHandler);
  ros::NodeHandle pnh("~");

  // create hardware interfaces
  bitbots_ros_control::WolfgangHardwareInterface hw(pnh);

  if (!hw.init(pnh)) {
    ROS_ERROR_STREAM("Failed to initialize hardware interface.");
    return 1;
  }

  // Create separate queue, because otherwise controller manager will freeze
  ros::NodeHandle nh;
  ros::AsyncSpinner spinner(5);
  spinner.start();
  controller_manager::ControllerManager *cm = new controller_manager::ControllerManager(&hw, nh);
  // load controller directly here so that we have control when we shut down
  // sometimes we want to only load some of the controllers
  bool only_imu, only_pressure;
  nh.param<bool>("/ros_control/only_imu", only_imu, false);
  nh.param<bool>("/ros_control/only_pressure", only_pressure, false);
  std::vector<std::string> names;

  if (only_imu){
    cm->loadController("imu_sensor_controller");
    names = {"imu_sensor_controller"};
  }else if(only_pressure){
    names = {};
  }else {
    cm->loadController("joint_state_controller");
    cm->loadController("imu_sensor_controller");
    cm->loadController("DynamixelController");
    names = {"joint_state_controller", "imu_sensor_controller", "DynamixelController"};
  }
  const std::vector<std::string> empty = {};

  // we have to start controller in own thread, otherwise it does not work, since the control manager needs to get its
  // first update before the controllers are started
  std::thread
      thread = std::thread(&controller_manager::ControllerManager::switchController, cm, names, empty, 2, true, 3);

  // diagnostics
  int diag_counter = 0;
  ros::Publisher diagnostic_pub = nh.advertise<diagnostic_msgs::DiagnosticArray>("/diagnostics", 10, true);
  diagnostic_msgs::DiagnosticArray array_msg = diagnostic_msgs::DiagnosticArray();
  std::vector<diagnostic_msgs::DiagnosticStatus> array = std::vector<diagnostic_msgs::DiagnosticStatus>();
  diagnostic_msgs::DiagnosticStatus status = diagnostic_msgs::DiagnosticStatus();
  // add prefix PS for pressure sensor to sort in diagnostic analyser
  status.name = "BUSBus";
  status.hardware_id = "Bus";

  // Start control loop
  ros::Time current_time = ros::Time::now();
  ros::Duration period = ros::Time::now() - current_time;
  bool first_update = true;
  float control_loop_hz = pnh.param("control_loop_hz", 1000);
  ros::Rate rate(control_loop_hz);
  ros::Time stop_time;
  bool shut_down_started = false;

  while (!request_shutdown || ros::Time::now().toSec() - stop_time.toSec() < 5) {
    hw.read(current_time, period);
    period = ros::Time::now() - current_time;
    current_time = ros::Time::now();

    // period only makes sense after the first update
    // therefore, the controller manager is only updated starting with the second iteration
    if (first_update) {
      first_update = false;
    } else {
      cm->update(current_time, period);
    }
    hw.write(current_time, period);
    ros::spinOnce();
    rate.sleep();

    // publish diagnostic messages each 100 frames
    if (diag_counter % 100 == 0) {
        // check if we are staying the correct cycle time. warning if we only get half
        array_msg.header.stamp = ros::Time::now();
        if(rate.cycleTime() < ros::Duration(1/control_loop_hz)*2){
          status.level = diagnostic_msgs::DiagnosticStatus::OK;
          status.message = "";
        }else{
          status.level = diagnostic_msgs::DiagnosticStatus::WARN;
          status.message = "Bus runs not at specified frequency";
        }
        array = std::vector<diagnostic_msgs::DiagnosticStatus>();
        array.push_back(status);
        array_msg.status = array;
        diagnostic_pub.publish(array_msg);
    }
    diag_counter++;

    if (request_shutdown && !shut_down_started) {
      stop_time = ros::Time::now();
      shut_down_started = true;
    }
  }
  thread.join();
  delete cm;
  ros::shutdown();
  return 0;
}
