import QtQuick 2.5
import QtQuick.Layouts 1.2

View {
    id: root
    name: "Exit"
    anchors.fill: parent

    Rectangle {
        anchors.fill: parent
        color: "black"

        Image {
            anchors.fill: parent
            source: "images/ratt_exitscreen.png"
            fillMode: Image.PreserveAspectFit
        }
    }

    function _show() {
        if (typeof tool !== "undefined" && tool) tool.visible = false;
        if (typeof status !== "undefined" && status) status.visible = false;
    }
}
